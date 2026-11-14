package de.aklozyp.moddexbackend.api.server.controller

import com.fasterxml.jackson.core.JsonGenerator
import com.fasterxml.jackson.databind.JsonSerializer
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.SerializerProvider
import com.fasterxml.jackson.databind.module.SimpleModule
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import de.aklozyp.moddexbackend.api.server.service.ServerSettingsPersistenceException
import de.aklozyp.moddexbackend.api.server.service.ServerSettingsService
import de.aklozyp.moddexbackend.api.server.service.SetupBootstrapProofService
import de.aklozyp.moddexbackend.api.server.service.SetupService
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.enums.ModDataProvider
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.Runs
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.spyk
import jakarta.servlet.ServletException
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.RepeatedTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.NullAndEmptySource
import org.junit.jupiter.params.provider.ValueSource
import org.springframework.http.MediaType
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder
import org.springframework.security.crypto.password.PasswordEncoder
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.MvcResult
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.util.Collections
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicReference

class SetupControllerTest {
    private val objectMapper = jacksonObjectMapper()
    private val passwordEncoder = BCryptPasswordEncoder(4)
    private val logger: Logger = mockk(relaxed = true)
    private val logMessages: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private lateinit var stateDir: Path
    private lateinit var directories: ModdexDirectories
    private lateinit var settingsService: ServerSettingsService
    private lateinit var proofService: SetupBootstrapProofService
    private var bootstrapToken: String? = null

    private val settingsFile: Path
        get() = directories.configDir.resolve("serversettings.json")

    private val proofFile: Path
        get() = directories.configDir.resolve(SetupBootstrapProofService.PROOF_FILE_NAME)

    @BeforeEach
    fun setUp() {
        stateDir = Files.createTempDirectory(Path.of("target").toAbsolutePath(), "setup-atomic-test-")
        directories = object : ModdexDirectories {
            override val configDir: Path = stateDir.resolve("config")
            override val dataDir: Path = stateDir.resolve("data")
            override val logsDir: Path = stateDir.resolve("logs")
        }
        proofService = SetupBootstrapProofService(directories, objectMapper, logger)
        settingsService = settingsService()
        every { logger.info(capture(logMessages)) } just Runs
        every { logger.warn(capture(logMessages)) } just Runs
        every { logger.error(capture(logMessages)) } just Runs
        bootstrapToken = proofService.issueNewProof()
    }

    @AfterEach
    fun cleanUp() {
        Files.walk(stateDir).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
        }
    }

    @RepeatedTest(5)
    fun parallelRequestsWithDifferentPasswordsHaveOnePersistedWinnerAndOneHttpConflict() {
        settingsService.updateServerSettings(ServerSettings().apply {
            projectPath = stateDir.resolve("custom-servers").toString()
            defaultJavaXmx = "4G"
            modProvider = ModDataProvider.CURSEFORGE
            curseForgeApiKey = PROVIDER_KEY
        })
        val hashingBarrier = CyclicBarrier(2)
        val concurrentEncoder = object : PasswordEncoder {
            override fun encode(rawPassword: CharSequence): String {
                hashingBarrier.await(10, SECONDS)
                return passwordEncoder.encode(rawPassword)
            }

            override fun matches(rawPassword: CharSequence, encodedPassword: String): Boolean =
                passwordEncoder.matches(rawPassword, encodedPassword)
        }
        val mockMvc = mockMvc(encoder = concurrentEncoder)
        val executor = Executors.newFixedThreadPool(2)
        val startBarrier = CyclicBarrier(2)
        val passwords = listOf("first-test-password", "second-test-password")
        val results = try {
            passwords.map { password ->
                executor.submit<MvcResult> {
                    startBarrier.await(10, SECONDS)
                    complete(mockMvc, password)
                }
            }.map { it.get(15, SECONDS) }
        } finally {
            executor.shutdownNow()
            assertThat(executor.awaitTermination(10, SECONDS)).isTrue()
        }

        assertThat(results.map { it.response.status }).containsExactlyInAnyOrder(200, 409)
        val winnerIndex = results.indexOfFirst { it.response.status == 200 }
        val loserIndex = 1 - winnerIndex
        assertThat(error(results[loserIndex])).isEqualTo("Setup already completed")
        assertThat(objectMapper.readTree(results[winnerIndex].response.contentAsString)["message"].asText())
            .isEqualTo("Setup completed")
        assertThat(proofFile).doesNotExist()

        val persisted = objectMapper.readValue(settingsFile.toFile(), ServerSettings::class.java)
        assertThat(passwordEncoder.matches(passwords[winnerIndex], persisted.adminPasswordHash)).isTrue()
        assertThat(passwordEncoder.matches(passwords[loserIndex], persisted.adminPasswordHash)).isFalse()
        assertThat(persisted.projectPath).isEqualTo(stateDir.resolve("custom-servers").toString())
        assertThat(persisted.defaultJavaXmx).isEqualTo("4G")
        assertThat(persisted.modProvider).isEqualTo(ModDataProvider.CURSEFORGE)
        assertThat(persisted.curseForgeApiKey).isEqualTo(PROVIDER_KEY)
        assertThat(Files.readString(settingsFile)).doesNotContain(*passwords.toTypedArray())

        val committed = Files.readString(settingsFile)
        val restartedMvc = mockMvc(settingsService())
        val status = restartedMvc.perform(get("/api/v1/setup/status")).andReturn()
        assertThat(status.response.status).isEqualTo(200)
        assertThat(objectMapper.readTree(status.response.contentAsString)["setupRequired"].asBoolean()).isFalse()
        assertThat(complete(restartedMvc, passwords[loserIndex]).response.status).isEqualTo(409)
        assertThat(Files.readString(settingsFile)).isEqualTo(committed)
        assertNoPendingFiles()
        assertNoSecretOutput(
            results + status,
            passwords + listOf(PROVIDER_KEY, persisted.adminPasswordHash!!, bootstrapToken ?: "")
        )
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = [" \t\n"])
    fun nullOrBlankStoredHashStillAllowsInitialSetup(storedHash: String?) {
        settingsService.updateServerSettings(ServerSettings().apply { adminPasswordHash = storedHash })
        val mockMvc = mockMvc()

        val initialStatus = mockMvc.perform(get("/api/v1/setup/status")).andReturn()
        assertThat(initialStatus.response.status).isEqualTo(200)
        assertThat(objectMapper.readTree(initialStatus.response.contentAsString)["setupRequired"].asBoolean()).isTrue()
        assertThat(complete(mockMvc, PASSWORD).response.status).isEqualTo(200)
        assertThat(passwordEncoder.matches(PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isTrue()
        assertThat(complete(mockMvc, "another-test-password").response.status).isEqualTo(409)
    }

    @Test
    fun freshSetupCreatesSettingsAndShortPasswordsDoNotPersistAnything() {
        val mockMvc = mockMvc()
        val shortPassword = complete(mockMvc, "short")
        assertThat(shortPassword.response.status).isEqualTo(400)
        assertThat(error(shortPassword)).isEqualTo("Password must be at least 8 characters")
        assertThat(Files.exists(settingsFile)).isFalse()

        assertThat(complete(mockMvc, PASSWORD).response.status).isEqualTo(200)
        val persisted = settingsService().getServerSettings()
        assertThat(passwordEncoder.matches(PASSWORD, persisted.adminPasswordHash)).isTrue()
        assertThat(persisted.projectPath).isEqualTo(directories.dataDir.toString())
        assertThat(persisted.defaultJavaXmx).isEqualTo(ServerSettingsService.DEFAULT_JAVA_XMX)
        assertThat(persisted.defaultJavaXms).isEqualTo(ServerSettingsService.DEFAULT_JAVA_XMS)
        assertThat(persisted.modProvider).isEqualTo(ModDataProvider.MODRINTH)
        assertNoPendingFiles()
    }

    @Test
    fun installedPasswordCannotBeOverwrittenByRepeatedSetup() {
        val installedHash = passwordEncoder.encode(PASSWORD)
        settingsService.updateServerSettings(ServerSettings().apply { adminPasswordHash = installedHash })
        val committed = Files.readString(settingsFile)

        val result = complete(mockMvc(settingsService()), "different-test-password")

        assertThat(result.response.status).isEqualTo(409)
        assertThat(error(result)).isEqualTo("Setup already completed")
        assertThat(Files.readString(settingsFile)).isEqualTo(committed)
        assertThat(passwordEncoder.matches(PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isTrue()
    }

    @Test
    fun setupWithoutWrongOrExpiredProofIsRejectedWithGuidanceAndStoresNothing() {
        val mockMvc = mockMvc()
        val invalidProofs = mapOf(
            "blank" to " \t\n",
            "wrong" to "not-the-issued-proof",
        )
        for ((label, proof) in invalidProofs) {
            val result = complete(mockMvc, "$label-proof-test-password", proof)
            assertThat(result.response.status).isEqualTo(403)
            val message = error(result)
            assertThat(message).contains(SetupBootstrapProofService.PROOF_FILE_NAME)
            assertThat(message).contains("restart the backend")
            assertThat(message).doesNotContain(bootstrapToken!!)
            assertThat(Files.exists(settingsFile)).isFalse()
        }

        // A request without the field at all (previous contract shape) is rejected the same way.
        val absentField = mockMvc.perform(
            post("/api/v1/setup/complete")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(mapOf("password" to PASSWORD)))
        ).andReturn()
        assertThat(absentField.response.status).isEqualTo(403)
        assertThat(error(absentField)).contains(SetupBootstrapProofService.PROOF_FILE_NAME)
        assertThat(Files.exists(settingsFile)).isFalse()

        // A proof whose recorded age exceeds the lifetime is rejected as expired.
        writeExpiredProofFile(bootstrapToken!!)
        val expired = complete(mockMvc, "expired-proof-test-password", bootstrapToken)
        assertThat(expired.response.status).isEqualTo(403)
        assertThat(error(expired)).doesNotContain(bootstrapToken!!)
        assertThat(Files.exists(settingsFile)).isFalse()
        assertNoPendingFiles()
    }

    @Test
    fun successfulSetupConsumesTheProofAndBlocksReplay() {
        val mockMvc = mockMvc()
        assertThat(complete(mockMvc, PASSWORD).response.status).isEqualTo(200)
        assertThat(proofFile).doesNotExist()
        assertThat(proofService.validate(bootstrapToken)).isFalse()

        val replay = complete(mockMvc, DIFFERENT_PASSWORD, bootstrapToken)

        assertThat(replay.response.status).isEqualTo(409)
        assertThat(error(replay)).isEqualTo("Setup already completed")
        assertThat(passwordEncoder.matches(PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isTrue()
        assertThat(passwordEncoder.matches(DIFFERENT_PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isFalse()
    }

    @Test
    fun restartedBackendRegeneratesTheProofAndThePreviousProofStopsWorking() {
        val staleToken = bootstrapToken
        bootstrapToken = proofService.issueNewProof()

        assertThat(bootstrapToken).isNotEqualTo(staleToken)
        assertThat(complete(mockMvc(), PASSWORD, staleToken).response.status).isEqualTo(403)
        assertThat(Files.exists(settingsFile)).isFalse()

        assertThat(complete(mockMvc(), PASSWORD, bootstrapToken).response.status).isEqualTo(200)
        assertThat(passwordEncoder.matches(PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isTrue()
    }

    @Test
    fun configuredInstallationIsBlockedByTheAdministratorCheckRegardlessOfProofs() {
        val installedHash = passwordEncoder.encode(PASSWORD)
        settingsService.updateServerSettings(ServerSettings().apply { adminPasswordHash = installedHash })
        // Startup of a configured installation removes a leftover proof file and issues no new one.
        ServerSettingsService(logger, objectMapper, directories, proofService).bootstrap()
        assertThat(proofFile).doesNotExist()

        val withIssuedProof = complete(mockMvc(settingsService()), DIFFERENT_PASSWORD, bootstrapToken)

        assertThat(withIssuedProof.response.status).isEqualTo(409)
        assertThat(error(withIssuedProof)).isEqualTo("Setup already completed")
        assertThat(passwordEncoder.matches(PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isTrue()
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = [" \t\n", DIFFERENT_PASSWORD])
    fun staleSettingsSnapshotCannotClearOrReplaceTheWinningAdmin(suppliedPassword: String?) {
        val staleSettings = settingsService.getServerSettings().apply {
            adminPasswordHash = suppliedPassword?.let {
                if (it.isBlank()) it else passwordEncoder.encode(it)
            }
            defaultJavaXmx = "6G"
        }
        assertThat(complete(mockMvc(), PASSWORD).response.status).isEqualTo(200)
        val winningHash = settingsService.getServerSettings().adminPasswordHash!!

        val updated = settingsService.updateServerSettings(staleSettings)

        assertThat(updated.adminPasswordHash).isEqualTo(winningHash)
        assertThat(settingsService().getServerSettings().defaultJavaXmx).isEqualTo("6G")
        settingsService.saveServerSettings(ServerSettings().apply { defaultJavaXms = "3G" })
        assertThat(settingsService().getServerSettings().defaultJavaXms).isEqualTo("3G")
        assertOnlyOriginalWinnerRemains(winningHash)
        assertNoPendingFiles()
    }

    @ParameterizedTest
    @ValueSource(strings = ["omitted", "null", "blank", "changed"])
    fun ordinarySettingsPutCannotClearOrReplaceTheWinningAdmin(hashField: String) {
        val mockMvc = mockMvc()
        assertThat(complete(mockMvc, PASSWORD).response.status).isEqualTo(200)
        val winningHash = settingsService.getServerSettings().adminPasswordHash!!
        val payload = mutableMapOf<String, Any?>("defaultJavaXmx" to "6G")
        when (hashField) {
            "null" -> payload["adminPasswordHash"] = null
            "blank" -> payload["adminPasswordHash"] = " \t\n"
            "changed" -> payload["adminPasswordHash"] = passwordEncoder.encode(DIFFERENT_PASSWORD)
        }

        val result = mockMvc.perform(
            put("/api/v1/serverSettings")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(payload))
        ).andReturn()

        assertThat(result.response.status).isEqualTo(200)
        assertThat(settingsService().getServerSettings().defaultJavaXmx).isEqualTo("6G")
        assertOnlyOriginalWinnerRemains(winningHash)
        assertNoPendingFiles()
    }

    @Test
    fun corruptExistingSettingsRefuseGenericWritesEvenWhenReadsReturnFallbackDefaults() {
        assertThat(complete(mockMvc(), PASSWORD).response.status).isEqualTo(200)
        val staleSettings = settingsService.getServerSettings()
        val invalidSettings =
            """{"adminPasswordHash":"${staleSettings.adminPasswordHash}","curseForgeApiKey":"$PROVIDER_KEY","broken":"""
        Files.writeString(settingsFile, invalidSettings)
        val fallbackSettings = settingsService.getServerSettings()
        assertThat(fallbackSettings.adminPasswordHash).isNull()

        assertThrows<ServerSettingsPersistenceException> {
            settingsService.updateServerSettings(fallbackSettings)
        }
        assertThrows<ServerSettingsPersistenceException> {
            settingsService.saveServerSettings(staleSettings)
        }
        val failure = assertThrows<ServletException> {
            mockMvc().perform(
                put("/api/v1/serverSettings")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("""{"defaultJavaXmx":"6G"}""")
            ).andReturn()
        }

        assertThat(failure.cause).isInstanceOf(ServerSettingsPersistenceException::class.java)
        assertThat(failure.cause!!.cause).isNull()
        assertThat(Files.readString(settingsFile)).isEqualTo(invalidSettings)
        assertNoPendingFiles()
        assertNoSecretOutput(emptyList(), listOf(PASSWORD, PROVIDER_KEY, staleSettings.adminPasswordHash!!))
    }

    @Test
    fun unreadableSettingsFailSafelyInsteadOfReopeningSetupOrOverwritingInstalledCredentials() {
        Files.createDirectories(directories.configDir)
        val invalidSettings = """{"adminPasswordHash":"installed-test-hash","curseForgeApiKey":"$PROVIDER_KEY","broken":"""
        Files.writeString(settingsFile, invalidSettings)
        val mockMvc = mockMvc()

        val status = mockMvc.perform(get("/api/v1/setup/status")).andReturn()
        val completion = complete(mockMvc, PASSWORD)

        assertSafePersistenceFailure(status)
        assertSafePersistenceFailure(completion)
        assertThat(Files.readString(settingsFile)).isEqualTo(invalidSettings)
        assertNoSecretOutput(listOf(status, completion), listOf(PASSWORD, PROVIDER_KEY, "installed-test-hash"))
        assertNoPendingFiles()
    }

    @Test
    fun configurationIoFailureReturns500AndCanBeRetriedAfterRepair() {
        directories.configDir.toFile().deleteRecursively()
        Files.writeString(directories.configDir, "configuration directory is blocked by a regular file")
        val mockMvc = mockMvc()

        assertSafePersistenceFailure(mockMvc.perform(get("/api/v1/setup/status")).andReturn())
        assertSafePersistenceFailure(complete(mockMvc, PASSWORD))
        assertThat(Files.isRegularFile(directories.configDir)).isTrue()

        Files.delete(directories.configDir)
        // The blocker destroyed the proof file; the backend regenerates it at startup,
        // so the repaired installation receives a fresh proof before setup succeeds.
        assertThat(proofService.validate(bootstrapToken)).isFalse()
        bootstrapToken = proofService.issueNewProof()
        assertThat(complete(mockMvc, PASSWORD).response.status).isEqualTo(200)
        assertThat(passwordEncoder.matches(PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isTrue()
    }

    @Test
    fun partialSerializationFailureDoesNotCommitAnAdminAndCanBeRetried() {
        settingsService.updateServerSettings(ServerSettings().apply { curseForgeApiKey = PROVIDER_KEY })
        val committed = Files.readString(settingsFile)
        val attemptedHash = AtomicReference<String>()
        val failingMvc = mockMvc(settingsService(failingMapper(attemptedHash)))

        val result = complete(failingMvc, PASSWORD)

        assertSafePersistenceFailure(result)
        assertThat(Files.readString(settingsFile)).isEqualTo(committed)
        assertThat(settingsService().isInitialAdminPasswordMissing()).isTrue()
        // The failed attempt did not commit the credential, so the proof stays valid for the retry.
        assertThat(proofFile).exists()
        assertNoPendingFiles()
        assertNoSecretOutput(listOf(result), listOf(PASSWORD, PROVIDER_KEY, attemptedHash.get(), SENSITIVE_FAILURE))

        assertThat(complete(mockMvc(), PASSWORD).response.status).isEqualTo(200)
        assertThat(passwordEncoder.matches(PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isTrue()
    }

    @Test
    fun failedSettingsWritePreservesAnAlreadyUsableInstalledAdmin() {
        settingsService.updateServerSettings(ServerSettings().apply {
            adminPasswordHash = passwordEncoder.encode(PASSWORD)
            curseForgeApiKey = PROVIDER_KEY
        })
        val committed = Files.readString(settingsFile)
        val failingService = settingsService(failingMapper(AtomicReference()))
        val updatedSettings = settingsService.getServerSettings().apply { defaultJavaXmx = "8G" }

        val failure = assertThrows<ServerSettingsPersistenceException> {
            failingService.updateServerSettings(updatedSettings)
        }

        assertThat(failure.cause).isNull()
        assertThat(Files.readString(settingsFile)).isEqualTo(committed)
        assertThat(passwordEncoder.matches(PASSWORD, settingsService().getServerSettings().adminPasswordHash)).isTrue()
        assertNoPendingFiles()
    }

    @ParameterizedTest
    @ValueSource(booleans = [false, true])
    fun failedAtomicMoveCleansPendingFileAndKeepsLiveSettingsUnchanged(alreadyConfigured: Boolean) {
        if (alreadyConfigured) {
            assertThat(complete(mockMvc(), PASSWORD).response.status).isEqualTo(200)
        } else {
            settingsService.updateServerSettings(ServerSettings().apply { curseForgeApiKey = PROVIDER_KEY })
        }
        val committed = Files.readString(settingsFile)
        val pendingFile = AtomicReference<Path>()
        val attemptedHash = AtomicReference<String>()
        val results = mutableListOf<MvcResult>()
        val failingService = spyk(settingsService)
        every { failingService.replaceSettingsFile(any()) } answers {
            val source = firstArg<Path>()
            pendingFile.set(source)
            attemptedHash.set(objectMapper.readTree(source.toFile())["adminPasswordHash"].asText())
            assertThat(source.parent).isEqualTo(directories.configDir)
            assertThat(attemptedHash.get()).isNotBlank()
            throw AtomicMoveNotSupportedException(
                source.toString(), settingsFile.toString(),
                "$SENSITIVE_FAILURE $PASSWORD $PROVIDER_KEY ${attemptedHash.get()}"
            )
        }
        if (alreadyConfigured) {
            val failure = assertThrows<ServerSettingsPersistenceException> {
                failingService.updateServerSettings(
                    settingsService.getServerSettings().apply { defaultJavaXmx = "8G" }
                )
            }
            assertThat(failure.cause).isNull()
        } else {
            results += complete(mockMvc(failingService), PASSWORD).also { assertSafePersistenceFailure(it) }
            // The failed attempt did not commit the credential, so the proof stays valid for the retry.
            assertThat(proofFile).exists()
        }

        assertThat(pendingFile.get()).isNotNull()
        assertThat(Files.exists(pendingFile.get())).isFalse()
        assertThat(Files.readString(settingsFile)).isEqualTo(committed)
        assertNoPendingFiles()
        assertNoSecretOutput(results, listOf(PASSWORD, PROVIDER_KEY, attemptedHash.get(), SENSITIVE_FAILURE))
        if (alreadyConfigured) {
            assertOnlyOriginalWinnerRemains(settingsService().getServerSettings().adminPasswordHash!!)
        } else {
            assertThat(settingsService().isInitialAdminPasswordMissing()).isTrue()
            assertThat(complete(mockMvc(), PASSWORD).response.status).isEqualTo(200)
        }
    }

    private fun settingsService(mapper: ObjectMapper = objectMapper): ServerSettingsService =
        ServerSettingsService(logger, mapper, directories, proofService)

    private fun mockMvc(
        service: ServerSettingsService = settingsService,
        encoder: PasswordEncoder = passwordEncoder
    ): MockMvc = MockMvcBuilders.standaloneSetup(
        SetupController(SetupService(service, encoder, logger)),
        ServerSettingsController(service, logger)
    ).build()

    private fun complete(mockMvc: MockMvc, password: String, proof: String? = bootstrapToken): MvcResult =
        mockMvc.perform(
            post("/api/v1/setup/complete")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(mapOf("password" to password, "bootstrapToken" to proof)))
        ).andReturn()

    private fun error(result: MvcResult): String =
        objectMapper.readTree(result.response.contentAsString)["error"].asText()

    private fun writeExpiredProofFile(token: String) {
        val expiredTimestamp = System.currentTimeMillis() - SetupBootstrapProofService.PROOF_LIFETIME.toMillis() - 60_000
        Files.writeString(
            proofFile,
            """{"token":"$token","createdAtEpochMillis":$expiredTimestamp}"""
        )
    }

    private fun assertSafePersistenceFailure(result: MvcResult) {
        assertThat(result.response.status).isEqualTo(500)
        assertThat(error(result)).isEqualTo(ServerSettingsPersistenceException().message)
        assertThat(error(result)).contains("Check", "then retry")
    }

    private fun assertNoPendingFiles() {
        Files.list(directories.configDir).use { paths ->
            assertThat(paths.map { it.fileName.toString() }.toList())
                .noneMatch { it.endsWith(".pending") }
        }
    }

    private fun assertOnlyOriginalWinnerRemains(winningHash: String) {
        val restartedService = settingsService()
        val persisted = objectMapper.readValue(settingsFile.toFile(), ServerSettings::class.java)
        assertThat(persisted.adminPasswordHash).isEqualTo(winningHash)
        assertThat(passwordEncoder.matches(PASSWORD, persisted.adminPasswordHash)).isTrue()
        assertThat(passwordEncoder.matches(DIFFERENT_PASSWORD, persisted.adminPasswordHash)).isFalse()
        assertThat(restartedService.isInitialAdminPasswordMissing()).isFalse()
        val repeatedSetup = complete(mockMvc(restartedService), DIFFERENT_PASSWORD)
        assertThat(repeatedSetup.response.status).isEqualTo(409)
        assertThat(error(repeatedSetup)).isEqualTo("Setup already completed")
        assertThat(restartedService.getServerSettings().adminPasswordHash).isEqualTo(winningHash)
    }

    private fun assertNoSecretOutput(results: List<MvcResult>, secrets: List<String>) {
        val output = results.joinToString { it.response.contentAsString } + logMessages.joinToString()
        assertThat(output).doesNotContain(*secrets.toTypedArray())
    }

    private fun failingMapper(attemptedHash: AtomicReference<String>): ObjectMapper {
        val module = SimpleModule().addSerializer(ServerSettings::class.java, object : JsonSerializer<ServerSettings>() {
            override fun serialize(value: ServerSettings, generator: JsonGenerator, provider: SerializerProvider) {
                attemptedHash.set(value.adminPasswordHash)
                generator.writeStartObject()
                generator.writeStringField("adminPasswordHash", value.adminPasswordHash)
                generator.flush()
                throw IOException("$SENSITIVE_FAILURE $PASSWORD $PROVIDER_KEY ${value.adminPasswordHash}")
            }
        })
        return jacksonObjectMapper().registerModule(module)
    }

    companion object {
        private const val PASSWORD = "initial-test-password"
        private const val DIFFERENT_PASSWORD = "different-test-password"
        private const val PROVIDER_KEY = "test-provider-key-not-for-logs"
        private const val SENSITIVE_FAILURE = "sensitive-test-serialization-error"
    }
}

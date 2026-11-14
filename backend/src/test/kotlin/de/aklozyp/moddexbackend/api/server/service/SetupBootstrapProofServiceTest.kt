package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.Runs
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.condition.EnabledOnOs
import org.junit.jupiter.api.condition.OS
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermission
import java.util.Collections

class SetupBootstrapProofServiceTest {
    private val objectMapper: ObjectMapper = jacksonObjectMapper()
    private val logger: Logger = mockk(relaxed = true)
    private val logMessages: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private lateinit var stateDir: Path
    private lateinit var directories: ModdexDirectories
    private lateinit var proofService: SetupBootstrapProofService

    private val proofFile: Path
        get() = directories.configDir.resolve(SetupBootstrapProofService.PROOF_FILE_NAME)

    @BeforeEach
    fun setUp() {
        stateDir = Files.createTempDirectory(Path.of("target").toAbsolutePath(), "setup-bootstrap-proof-test-")
        directories = object : ModdexDirectories {
            override val configDir: Path = stateDir.resolve("config")
            override val dataDir: Path = stateDir.resolve("data")
            override val logsDir: Path = stateDir.resolve("logs")
        }
        proofService = SetupBootstrapProofService(directories, objectMapper, logger)
        every { logger.info(capture(logMessages)) } just Runs
        every { logger.warn(capture(logMessages)) } just Runs
        every { logger.error(capture(logMessages)) } just Runs
    }

    @AfterEach
    fun cleanUp() {
        Files.walk(stateDir).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
        }
    }

    @Test
    fun issuedProofIsStoredWithOwnerOnlyPermissionsAndNeverLogged() {
        val token = proofService.issueNewProof()

        assertThat(token).isNotBlank()
        assertThat(token).matches("[0-9a-f]{64}")
        assertThat(proofFile).exists()
        val proof = objectMapper.readValue(proofFile.toFile(), SetupBootstrapProofService.SetupBootstrapProof::class.java)
        assertThat(proof.token).isEqualTo(token)
        val now = System.currentTimeMillis()
        assertThat(proof.createdAtEpochMillis).isBetween(now - 10_000, now)

        val output = logMessages.joinToString()
        assertThat(output).doesNotContain(token)
        assertThat(output).contains(SetupBootstrapProofService.PROOF_FILE_NAME)
        assertThat(output).contains("24 hours")
    }

    @Test
    @EnabledOnOs(OS.LINUX, OS.MAC)
    fun issuedProofFileIsOwnerOnlyOnPosixSystems() {
        proofService.issueNewProof()

        val permissions = Files.getPosixFilePermissions(proofFile)
        assertThat(permissions).containsExactlyInAnyOrder(
            PosixFilePermission.OWNER_READ,
            PosixFilePermission.OWNER_WRITE,
        )
    }

    @Test
    fun successiveProofsDifferAndInvalidateThePreviousToken() {
        val first = proofService.issueNewProof()
        assertThat(proofService.validate(first)).isTrue()

        val second = proofService.issueNewProof()

        assertThat(second).isNotEqualTo(first)
        assertThat(proofService.validate(first)).isFalse()
        assertThat(proofService.validate(second)).isTrue()
    }

    @Test
    fun missingBlankWrongOrCorruptProofsAreRejected() {
        assertThat(proofService.validate(null)).isFalse()
        assertThat(proofService.validate("")).isFalse()
        assertThat(proofService.validate(" \t\n")).isFalse()
        assertThat(proofService.validate("unknown-proof")).isFalse()

        val token = proofService.issueNewProof()!!
        assertThat(proofService.validate(token)).isTrue()
        assertThat(proofService.validate(" $token ")).isTrue()

        Files.writeString(proofFile, """{"token":"$token","broken"""")
        assertThat(proofService.validate(token)).isFalse()

        Files.writeString(proofFile, """{"token":"  ","createdAtEpochMillis":${System.currentTimeMillis()}}""")
        assertThat(proofService.validate("anything")).isFalse()
    }

    @Test
    fun expiredProofIsRejectedWhileFreshProofWithinLifetimeIsAccepted() {
        val token = "a".repeat(64)
        val now = System.currentTimeMillis()
        val lifetimeMillis = SetupBootstrapProofService.PROOF_LIFETIME.toMillis()

        writeProofFile(token, now - lifetimeMillis + 60_000)
        assertThat(proofService.validate(token)).isTrue()

        writeProofFile(token, now - lifetimeMillis - 60_000)
        assertThat(proofService.validate(token)).isFalse()
    }

    @Test
    fun consumeRemovesTheProofAndToleratesAMissingFile() {
        proofService.issueNewProof()
        assertThat(proofFile).exists()

        proofService.consume()
        assertThat(proofFile).doesNotExist()

        proofService.consume()
        assertThat(proofFile).doesNotExist()
    }

    @Test
    fun failedConsumptionIsLoggedInsteadOfFailingTheCaller() {
        proofService.issueNewProof()
        // A non-empty directory at the proof path makes the deletion fail deterministically
        // on every platform, including CI containers running as root, where POSIX permission
        // bits do not bind for the root account. The contract under test is unchanged: a
        // failing consumption is warn-logged instead of thrown.
        Files.delete(proofFile)
        Files.createDirectory(proofFile)
        Files.writeString(proofFile.resolve("placeholder.txt"), "blocks the directory deletion")

        proofService.consume()

        assertThat(proofFile).exists()
        assertThat(logMessages.joinToString()).contains("Could not remove the used setup bootstrap proof file")
    }

    @Test
    fun unwritableProofLocationFailsClosedWithoutAToken() {
        Files.createDirectories(directories.configDir.parent)
        Files.writeString(directories.configDir, "configuration directory is blocked by a regular file")

        val token = proofService.issueNewProof()

        assertThat(token).isNull()
        assertThat(logMessages.joinToString()).contains("Could not write the setup bootstrap proof file")
        assertThat(proofService.validate("anything")).isFalse()
    }

    @Test
    fun invalidProofMessageGuidesWithoutRevealingTheProof() {
        val token = proofService.issueNewProof()!!

        val message = proofService.invalidProofMessage()

        assertThat(message).contains(SetupBootstrapProofService.PROOF_FILE_NAME)
        assertThat(message).contains("restart the backend")
        assertThat(message).doesNotContain(token)
    }

    @Test
    fun settingsBootstrapIssuesAProofOnlyWhileSetupIsRequired() {
        val settingsService = ServerSettingsService(logger, objectMapper, directories, proofService)
        settingsService.bootstrap()
        assertThat(proofFile).exists()

        val staleToken = objectMapper.readValue(proofFile.toFile(), SetupBootstrapProofService.SetupBootstrapProof::class.java).token
        settingsService.updateServerSettings(ServerSettings().apply { adminPasswordHash = "installed-test-hash" })
        ServerSettingsService(logger, objectMapper, directories, proofService).bootstrap()

        assertThat(proofFile).doesNotExist()
        assertThat(proofService.validate(staleToken)).isFalse()
    }

    @Test
    fun firstAdminCommitRequiresAValidProofAndConsumesIt() {
        val settingsService = ServerSettingsService(logger, objectMapper, directories, proofService)
        val passwordHash = "test-password-hash-not-a-real-bcrypt-value"

        val withoutProof = assertThrows<SetupBootstrapProofInvalidException> {
            settingsService.initializeAdminPassword(passwordHash, null)
        }
        assertThat(withoutProof.message).contains(SetupBootstrapProofService.PROOF_FILE_NAME)
        assertThat(proofFile).doesNotExist()

        proofService.issueNewProof()
        val wrongProof = assertThrows<SetupBootstrapProofInvalidException> {
            settingsService.initializeAdminPassword(passwordHash, "wrong-proof")
        }
        assertThat(wrongProof.message).doesNotContain("wrong-proof")
        assertThat(proofFile).exists()

        val token = objectMapper.readValue(proofFile.toFile(), SetupBootstrapProofService.SetupBootstrapProof::class.java).token
        settingsService.initializeAdminPassword(passwordHash, token)
        assertThat(settingsService.getServerSettings().adminPasswordHash).isEqualTo(passwordHash)
        assertThat(proofFile).doesNotExist()

        assertThrows<SetupAlreadyCompletedException> {
            settingsService.initializeAdminPassword("other-test-password-hash", token)
        }
        assertThat(settingsService.getServerSettings().adminPasswordHash).isEqualTo(passwordHash)
    }

    @Test
    fun failedFirstAdminPersistenceKeepsTheProofValidForTheDocumentedRetry() {
        val attemptedHash = "attempted-test-password-hash"
        val failingMapper = jacksonObjectMapper().registerModule(
            com.fasterxml.jackson.databind.module.SimpleModule().addSerializer(
                ServerSettings::class.java,
                object : com.fasterxml.jackson.databind.JsonSerializer<ServerSettings>() {
                    override fun serialize(
                        value: ServerSettings,
                        generator: com.fasterxml.jackson.core.JsonGenerator,
                        provider: com.fasterxml.jackson.databind.SerializerProvider,
                    ) {
                        generator.flush()
                        throw java.io.IOException("injected test serialization failure")
                    }
                }
            )
        )
        val failingService = ServerSettingsService(logger, failingMapper, directories, proofService)
        val token = proofService.issueNewProof()!!

        assertThrows<ServerSettingsPersistenceException> {
            failingService.initializeAdminPassword(attemptedHash, token)
        }

        assertThat(proofFile).exists()
        assertThat(proofService.validate(token)).isTrue()

        val repairedService = ServerSettingsService(logger, objectMapper, directories, proofService)
        repairedService.initializeAdminPassword(attemptedHash, token)
        assertThat(repairedService.getServerSettings().adminPasswordHash).isEqualTo(attemptedHash)
        assertThat(proofFile).doesNotExist()
    }

    private fun writeProofFile(token: String, createdAtEpochMillis: Long) {
        Files.createDirectories(directories.configDir)
        Files.writeString(
            proofFile,
            """{"token":"$token","createdAtEpochMillis":$createdAtEpochMillis}"""
        )
    }
}

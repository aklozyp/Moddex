package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.enums.ModDataProvider
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
import java.nio.file.Files
import java.nio.file.Path
import java.util.Collections

/**
 * Covers the session-revocation stamp (issue #267): credential changes bump a persistent
 * revision, previously issued tokens stop validating, ordinary settings updates never
 * revoke, and the revision survives a simulated process restart. Audit assertions check
 * the structured revocation event without any secret material.
 */
class PasswordRevocationStampTest {
    private val objectMapper = jacksonObjectMapper()
    private val logger: Logger = mockk(relaxed = true)
    private val logMessages: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private lateinit var stateDir: Path
    private lateinit var directories: ModdexDirectories
    private lateinit var proofService: SetupBootstrapProofService

    private val settingsFile: Path
        get() = directories.configDir.resolve("serversettings.json")

    @BeforeEach
    fun setUp() {
        stateDir = Files.createTempDirectory(Path.of("target").toAbsolutePath(), "password-revocation-test-")
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

    private fun settingsService(): ServerSettingsService =
        ServerSettingsService(logger, objectMapper, directories, proofService).also { it.bootstrap() }

    private fun issueBootstrapProof(): String = requireNotNull(proofService.issueNewProof())

    private fun jwtService(settingsService: ServerSettingsService): JwtService =
        JwtService(settingsService).also { it.init() }

    @Test
    fun credentialChangeBumpsRevisionAndRevokesPreviouslyIssuedTokens() {
        val service = settingsService()
        val jwt = jwtService(service)

        service.initializeAdminPassword(HASH_ONE, issueBootstrapProof())
        assertThat(persistedRevision()).isEqualTo(1L)
        val tokenAtRevisionOne = jwt.generateToken(ADMIN_SUBJECT)
        assertThat(jwt.validateToken(tokenAtRevisionOne)).isTrue()

        service.changeAdminPassword(HASH_ONE, HASH_TWO)

        assertThat(persistedRevision()).isEqualTo(2L)
        assertThat(jwt.validateToken(tokenAtRevisionOne)).isFalse()
        assertThat(jwt.validateToken(jwt.generateToken(ADMIN_SUBJECT))).isTrue()
    }

    @Test
    fun revisionSurvivesSimulatedProcessRestartAndIsStillEnforced() {
        val firstProcessSettings = settingsService()
        val firstProcessJwt = jwtService(firstProcessSettings)

        firstProcessSettings.initializeAdminPassword(HASH_ONE, issueBootstrapProof())
        val oldToken = firstProcessJwt.generateToken(ADMIN_SUBJECT)
        firstProcessSettings.changeAdminPassword(HASH_ONE, HASH_TWO)
        val tokenAtRevisionTwo = firstProcessJwt.generateToken(ADMIN_SUBJECT)

        // Fresh instances over the same directories simulate a backend restart. JWT signing
        // keys are generated per process, so every token of the first process is invalid on
        // the restarted one regardless of revision; the assertion proves the persistence and
        // continued enforcement of the revocation stamp, not cross-restart token validity.
        val restartedSettings = settingsService()
        val restartedJwt = jwtService(restartedSettings)

        assertThat(restartedSettings.getPasswordRevision()).isEqualTo(2L)
        assertThat(restartedJwt.validateToken(oldToken)).isFalse()
        assertThat(restartedJwt.validateToken(tokenAtRevisionTwo)).isFalse()
        val restartedProcessToken = restartedJwt.generateToken(ADMIN_SUBJECT)
        assertThat(restartedJwt.validateToken(restartedProcessToken)).isTrue()

        // The persisted stamp keeps enforcing revocation in the restarted process.
        restartedSettings.changeAdminPassword(HASH_TWO, HASH_ONE)
        assertThat(restartedSettings.getPasswordRevision()).isEqualTo(3L)
        assertThat(restartedJwt.validateToken(restartedProcessToken)).isFalse()
        assertThat(restartedJwt.validateToken(restartedJwt.generateToken(ADMIN_SUBJECT))).isTrue()
    }

    @Test
    fun ordinarySettingsUpdateNeverRevokesSessionsOrTrustsClientRevision() {
        val service = settingsService()
        val jwt = jwtService(service)

        service.initializeAdminPassword(HASH_ONE, issueBootstrapProof())
        val activeToken = jwt.generateToken(ADMIN_SUBJECT)
        assertThat(jwt.validateToken(activeToken)).isTrue()

        val snapshot = ServerSettings().apply {
            projectPath = directories.dataDir.resolve("instances").toString()
            modProvider = ModDataProvider.CURSEFORGE
            adminPasswordHash = HASH_TWO
            passwordRevision = 999L
        }
        service.updateServerSettings(snapshot)

        val persisted = objectMapper.readValue<ServerSettings>(settingsFile.toFile())
        assertThat(persisted.adminPasswordHash).isEqualTo(HASH_ONE)
        assertThat(persisted.passwordRevision).isEqualTo(1L)
        assertThat(service.getPasswordRevision()).isEqualTo(1L)
        assertThat(jwt.validateToken(activeToken)).isTrue()
        // Setup itself audits a PASSWORD_SET revocation; a settings update must not
        // record a credential change.
        assertThat(logMessages.none { it.contains("reason=PASSWORD_CHANGED") }).isTrue()
    }

    @Test
    fun concurrentChangeIsRefusedByCompareAndSetWithoutRevoking() {
        val service = settingsService()
        val jwt = jwtService(service)

        service.initializeAdminPassword(HASH_ONE, issueBootstrapProof())
        val activeToken = jwt.generateToken(ADMIN_SUBJECT)

        assertThrows<ConcurrentPasswordChangeException> {
            service.changeAdminPassword("not-the-installed-hash", HASH_TWO)
        }

        assertThat(persistedRevision()).isEqualTo(1L)
        assertThat(jwt.validateToken(activeToken)).isTrue()
        assertThat(logMessages.none { it.contains("reason=PASSWORD_CHANGED") }).isTrue()
    }

    @Test
    fun preSetupSettingsPutInstallingCredentialStampsRevisionAndAuditsRevocation() {
        val service = settingsService()
        val jwt = jwtService(service)

        val tokenWithoutRevision = jwt.generateToken(ADMIN_SUBJECT)
        assertThat(jwt.validateToken(tokenWithoutRevision)).isTrue()

        val snapshot = ServerSettings().apply {
            projectPath = directories.dataDir.resolve("instances").toString()
            adminPasswordHash = HASH_ONE
        }
        service.updateServerSettings(snapshot)

        assertThat(persistedRevision()).isEqualTo(1L)
        // Tokens issued before any revision was recorded carry no revision claim and are revoked.
        assertThat(jwt.validateToken(tokenWithoutRevision)).isFalse()
        assertThat(logMessages.count { it.contains("AUTH_SESSIONS_REVOKED") }).isEqualTo(1)
        assertThat(logMessages.single { it.contains("AUTH_SESSIONS_REVOKED") })
            .contains("reason=PASSWORD_SET")
            .doesNotContain(HASH_ONE)
    }

    @Test
    fun revocationAuditNamesEventAndReasonWithoutSecrets() {
        val service = settingsService()
        service.initializeAdminPassword(HASH_ONE, issueBootstrapProof())
        service.changeAdminPassword(HASH_ONE, HASH_TWO)

        val changedEvents = logMessages.filter { it.contains("AUTH_SESSIONS_REVOKED") }
        assertThat(changedEvents).hasSize(2)
        assertThat(changedEvents.any { it.contains("reason=PASSWORD_CHANGED") }).isTrue()
        assertThat(changedEvents.any { it.contains("reason=PASSWORD_SET") }).isTrue()
        changedEvents.forEach { event ->
            assertThat(event).contains("actor=admin").contains("passwordRevision=")
            assertThat(event).doesNotContain(HASH_ONE).doesNotContain(HASH_TWO)
        }
    }

    @Test
    fun changeWithoutInstalledCredentialIsRefused() {
        val service = settingsService()

        assertThrows<AdminPasswordMissingException> {
            service.changeAdminPassword(HASH_ONE, HASH_TWO)
        }
        assertThat(persistedRevision()).isNull()
    }

    private fun persistedRevision(): Long? =
        objectMapper.readValue<ServerSettings>(settingsFile.toFile()).passwordRevision

    companion object {
        private const val ADMIN_SUBJECT = "admin"
        // Test-only BCrypt-like fixture strings; they stand in for stored hashes and never
        // represent a real credential.
        private const val HASH_ONE = "\$2a\$10\$fixture-hash-one-value-for-tests"
        private const val HASH_TWO = "\$2a\$10\$fixture-hash-two-value-for-tests"
    }
}

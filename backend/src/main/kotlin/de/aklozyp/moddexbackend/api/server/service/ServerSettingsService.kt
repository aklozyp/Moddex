package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.enums.ModDataProvider
import de.aklozyp.moddexbackend.services.Logger
import jakarta.annotation.PostConstruct
import org.springframework.stereotype.Service
import java.io.File
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING

@Service
class ServerSettingsService(
    private val logger: Logger,
    private val objectMapper: ObjectMapper,
    private val directories: ModdexDirectories,
    private val setupBootstrapProofService: SetupBootstrapProofService,
) {
    private val etcDir: Path
        get() = directories.configDir
    private val settingsFile: Path
        get() = etcDir.resolve("serversettings.json")
    private val defaultRoot: File
        get() = directories.dataDir.toFile()

    @PostConstruct
    fun bootstrap() {
        try {
            if (!Files.exists(etcDir)) {
                Files.createDirectories(etcDir)
                logger.info("Created server settings directory at ${etcDir.toAbsolutePath()}")
            }
        } catch (e: Exception) {
            logger.warn("Could not create ${etcDir.toAbsolutePath()}: ${e.message}")
        }
        ensureDefaultRoot()
        try {
            initServerSettings()
        } catch (e: Exception) {
            logger.warn("Failed to initialize ServerSettings at startup: ${e.message}")
        }
        refreshSetupBootstrapProof()
    }

    /**
     * Issues #265: while setup is still required, every startup issues a fresh
     * one-time bootstrap proof, so a proof from an earlier session never works.
     * A configured installation gets no proof; leftovers are removed. When the
     * settings cannot be read strictly, no proof is issued (fail closed).
     */
    private fun refreshSetupBootstrapProof() {
        val setupRequired = try {
            readServerSettings().adminPasswordHash.isNullOrBlank()
        } catch (_: ServerSettingsPersistenceException) {
            null
        }
        if (setupRequired == true) {
            setupBootstrapProofService.issueNewProof()
        } else {
            setupBootstrapProofService.consume()
        }
    }

    fun getServerSettings(): ServerSettings {
        return try {
            readServerSettings()
        } catch (_: ServerSettingsPersistenceException) {
            defaultSettings()
        }
    }

    @Synchronized
    fun isInitialAdminPasswordMissing(): Boolean {
        return readServerSettings().adminPasswordHash.isNullOrBlank()
    }

    /**
     * Strictly reads the installed administrator hash for security-relevant decisions.
     * Unreadable settings throw instead of returning a default snapshot.
     */
    fun getInstalledAdminPasswordHash(): String? {
        return readServerSettings().adminPasswordHash
    }

    /**
     * Strictly reads the persisted credential revision that issued tokens are checked
     * against. Unreadable settings throw; callers must fail closed.
     */
    fun getPasswordRevision(): Long? {
        return readServerSettings().passwordRevision
    }

    // Share the settings writer's monitor so the first-admin check, the bootstrap
    // proof validation, the commit, and the proof consumption cannot interleave.
    @Synchronized
    fun initializeAdminPassword(passwordHash: String, bootstrapProof: String?) {
        val settings = readServerSettings()
        val installedHash = settings.adminPasswordHash
        if (!installedHash.isNullOrBlank()) {
            throw SetupAlreadyCompletedException()
        }
        if (!setupBootstrapProofService.validate(bootstrapProof)) {
            throw SetupBootstrapProofInvalidException(setupBootstrapProofService.invalidProofMessage())
        }
        settings.adminPasswordHash = passwordHash
        val revokedRevision = markCredentialReplaced(installedHash, settings)
        persistServerSettings(settings)
        // Consume the proof only after the credential is committed, so a failed
        // persistence attempt keeps it valid for the documented retry.
        setupBootstrapProofService.consume()
        if (revokedRevision != null) {
            logSessionsRevoked(revokedRevision, REVOCATION_REASON_PASSWORD_SET)
        }
    }

    /**
     * Replaces the administrator credential. [expectedCurrentHash] is the hash the caller
     * verified the current password against; the compare-and-set under the settings lock
     * refuses the change when the credential moved in the meantime. The persisted revision
     * is incremented so previously issued tokens no longer validate.
     */
    @Synchronized
    fun changeAdminPassword(expectedCurrentHash: String, newPasswordHash: String) {
        val settings = readServerSettings()
        val installedHash = settings.adminPasswordHash
        if (installedHash.isNullOrBlank()) {
            throw AdminPasswordMissingException()
        }
        if (installedHash != expectedCurrentHash) {
            throw ConcurrentPasswordChangeException()
        }
        settings.adminPasswordHash = newPasswordHash
        val revokedRevision = markCredentialReplaced(installedHash, settings)
        persistServerSettings(settings)
        if (revokedRevision != null) {
            logSessionsRevoked(revokedRevision, REVOCATION_REASON_PASSWORD_CHANGED)
        }
    }

    @Synchronized
    fun updateServerSettings(serverSettings: ServerSettings): ServerSettings {
        // A pre-setup snapshot or partial settings PUT must not replace the winning credential
        // or move the persisted session-revocation revision.
        val installed = readServerSettings()
        val installedHash = installed.adminPasswordHash
        if (!installedHash.isNullOrBlank()) {
            serverSettings.adminPasswordHash = installedHash
        }
        serverSettings.passwordRevision = installed.passwordRevision
        val revokedRevision = markCredentialReplaced(installedHash, serverSettings)
        val saved = persistServerSettings(serverSettings)
        if (revokedRevision != null) {
            logSessionsRevoked(revokedRevision, REVOCATION_REASON_PASSWORD_SET)
        }
        return saved
    }

    /**
     * Records a credential transition before persisting: whenever a nonblank hash replaces a
     * different value, the revision is bumped so tokens issued before the change are revoked.
     * Ordinary settings updates keep the installed hash unchanged and therefore never revoke.
     * Returns the new revision, or null when the credential did not change.
     */
    private fun markCredentialReplaced(previousHash: String?, updated: ServerSettings): Long? {
        val newHash = updated.adminPasswordHash
        if (newHash.isNullOrBlank() || newHash == previousHash) {
            return null
        }
        val revision = (updated.passwordRevision ?: 0L) + 1L
        updated.passwordRevision = revision
        return revision
    }

    /**
     * Audit marker for session revocation (issue #267). Structured log event with reason and
     * pseudonymous actor; it deliberately contains no passwords, hashes, or tokens. A dedicated
     * audit subsystem is not available at this stage, so this timestamped log event is the
     * revocation record.
     */
    private fun logSessionsRevoked(revision: Long, reason: String) {
        logger.warn(
            "AUTH_SESSIONS_REVOKED reason=$reason actor=admin passwordRevision=$revision " +
                "nextAction=Previously issued admin tokens are no longer valid; sign in again with the current password."
        )
    }

    private fun persistServerSettings(serverSettings: ServerSettings): ServerSettings {
        try {
            Files.createDirectories(etcDir)
            applyDefaults(serverSettings)
            serverSettings.curseForgeApiKey = serverSettings.curseForgeApiKey?.trim()?.takeUnless { it.isEmpty() }
            writeJsonAtomically(settingsFile, objectMapper, serverSettings, logger, ::replaceSettingsFile)
            logger.info("Saved ServerSettings to ${settingsFile.toAbsolutePath()}")
        } catch (_: Exception) {
            logger.error("Failed to save server settings. Check the configuration directory and its permissions.")
            throw ServerSettingsPersistenceException()
        }
        return serverSettings
    }

    internal fun replaceSettingsFile(pendingFile: Path) {
        Files.move(pendingFile, settingsFile, ATOMIC_MOVE, REPLACE_EXISTING)
    }

    fun saveServerSettings(settings: ServerSettings) {
        updateServerSettings(settings)
    }

    @Synchronized
    fun initServerSettings() {
        if (!Files.exists(settingsFile)) {
            logger.info("Initializing default ServerSettings at ${settingsFile.toAbsolutePath()}")
            updateServerSettings(defaultSettings())
        }
        ensureDefaultRoot()
    }

    private fun readServerSettings(): ServerSettings {
        return try {
            Files.newInputStream(settingsFile).use { input ->
                objectMapper.readValue<ServerSettings>(input).also { applyDefaults(it) }
            }
        } catch (_: NoSuchFileException) {
            defaultSettings()
        } catch (_: Exception) {
            logger.error("Failed to read server settings. Check the configuration file and its permissions.")
            throw ServerSettingsPersistenceException()
        }
    }

    private fun defaultSettings(): ServerSettings = ServerSettings().apply {
        projectPath = defaultRoot.absolutePath
        defaultJavaXmx = DEFAULT_JAVA_XMX
        defaultJavaXms = DEFAULT_JAVA_XMS
        modProvider = ModDataProvider.MODRINTH
    }

    private fun applyDefaults(settings: ServerSettings) {
        if (settings.projectPath.isNullOrBlank()) {
            settings.projectPath = defaultRoot.absolutePath
        }
        if (settings.defaultJavaXmx.isNullOrBlank()) {
            settings.defaultJavaXmx = DEFAULT_JAVA_XMX
        }
        if (settings.defaultJavaXms.isNullOrBlank()) {
            settings.defaultJavaXms = DEFAULT_JAVA_XMS
        }
        if (settings.modProvider == null) {
            settings.modProvider = ModDataProvider.MODRINTH
        }
    }

    companion object {
        const val DEFAULT_JAVA_XMX = "2G"
        const val DEFAULT_JAVA_XMS = "1G"
        const val REVOCATION_REASON_PASSWORD_CHANGED = "PASSWORD_CHANGED"
        const val REVOCATION_REASON_PASSWORD_SET = "PASSWORD_SET"
    }

    private fun ensureDefaultRoot() {
        try {
            if (!defaultRoot.exists()) {
                defaultRoot.mkdirs()
                logger.info("Created default server root ${defaultRoot.absolutePath}")
            }
        } catch (e: Exception) {
            logger.warn("Could not create default root ${defaultRoot.absolutePath}: ${e.message}")
        }
    }
}

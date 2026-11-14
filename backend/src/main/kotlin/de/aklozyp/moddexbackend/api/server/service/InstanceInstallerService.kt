package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.nio.file.Path
import java.util.UUID

@Service
class InstanceInstallerService(
    private val versionService: VersionService,
    private val serverSettingsService: ServerSettingsService,
    private val installerCommandRunner: InstallerCommandRunner,
    private val artifactDownloader: SecureArtifactDownloader,
    private val originPolicy: ArtifactOriginPolicy,
    private val logger: Logger,
    private val startManifestStore: InstanceStartManifestStore,
) {

    fun downloadInstaller(instance: Instance, directory: Path) {
        val loader = instance.modLoader ?: ModLoader.VANILLA

        if (loader == ModLoader.VANILLA) {
            // The vanilla server jar is itself the startable artifact, so it is
            // stored under the name the start path resolves (see LoaderStartDiscovery).
            // There is no separate installer to run: invoking the jar here would
            // execute an unbounded game server inside the creation request,
            // while the explicit start remains a separate user action.
            downloadVanillaServerJar(instance, directory, VANILLA_SERVER_FILENAME)
            startManifestStore.record(instance, directory)
            logger.info("Vanilla server jar prepared for instance id=${instance.id}; starting the server remains an explicit action")
            return
        }

        downloadLoaderInstaller(instance, directory, loader)
        if (loader == ModLoader.FABRIC || loader == ModLoader.QUILT) {
            downloadVanillaServerJar(instance, directory, VANILLA_SERVER_FILENAME)
        }

        runInstaller(instance, directory)
        // The installation state is coherent only here: the launch contract the
        // installer wrote (argument files or a launch jar) is resolved once and
        // stored, so the start phase no longer has to rediscover it.
        startManifestStore.record(instance, directory)
    }

    private fun downloadLoaderInstaller(instance: Instance, directory: Path, loader: ModLoader) {
        val downloadUrl = modLoaderInstallerUrl(loader, instance)
        if (downloadUrl.isBlank()) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "No download available for loader ${loader.name}")
        }

        artifactDownloader.download(
            ArtifactDownloadRequest(
                artifactName = LOADER_INSTALLER_ARTIFACT,
                downloadUrl = downloadUrl,
                allowedHosts = originPolicy.installerHosts(loader),
                instanceId = instance.id,
            ),
            directory.resolve(INSTALLER_FILENAME),
        )
    }

    private fun downloadVanillaServerJar(instance: Instance, directory: Path, fileName: String) {
        val mcVersion = instance.gameVersion?.takeIf { it.isNotBlank() }
            ?: throw ResponseStatusException(HttpStatus.BAD_REQUEST, "gameVersion is required to download the vanilla server jar")
        val download = versionService.minecraftServerDownload(mcVersion)
        if (download == null || download.url.isNullOrBlank()) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "No Minecraft server jar found for version $mcVersion")
        }

        artifactDownloader.download(
            ArtifactDownloadRequest(
                artifactName = VANILLA_SERVER_ARTIFACT,
                downloadUrl = download.url,
                allowedHosts = originPolicy.vanillaServerHosts,
                instanceId = instance.id,
                expectedSha1 = download.sha1,
                expectedSizeBytes = download.size,
            ),
            directory.resolve(fileName),
        )
    }

    private fun modLoaderInstallerUrl(loader: ModLoader, instance: Instance): String {
        val loaderVersion = instance.modLoaderVersion?.takeIf { it.isNotBlank() }
            ?: throw ResponseStatusException(HttpStatus.BAD_REQUEST, "modLoaderVersion is required for loader ${loader.name}")
        val loaderKey = when (loader) {
            ModLoader.FORGE -> "forge"
            ModLoader.NEOFORGE -> "neoforge"
            ModLoader.FABRIC -> "fabric"
            ModLoader.QUILT -> "quilt"
            ModLoader.VANILLA -> throw IllegalArgumentException("VANILLA loader does not have installer URL")
        }

        val mcVersion = instance.gameVersion

        return try {
            versionService.loaderDownloadUrl(loaderKey, loaderVersion, mcVersion)
        } catch (ex: IllegalArgumentException) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, ex.message ?: "Invalid loader configuration", ex)
        }
    }

    private fun runInstaller(instance: Instance, directory: Path) {
        val (xmx, xms) = resolveJvmMemory(instance)
        val command = buildInstallerCommand(instance, xmx, xms)
        val jobId = installJobId(instance)

        val exitCode = try {
            installerCommandRunner.run(command, directory, jobId)
        } catch (e: InstallerCommandTimeoutException) {
            val guidance = "The installer did not finish within the configured time budget and was stopped (job $jobId). " +
                "Last captured output: ${safeExcerpt(jobId)} " +
                "Next action: check the backend log for the full installer output, then retry the installation; " +
                "raise moddex.installer.timeout-ms only if the installer is legitimately slow."
            logger.error("$guidance Instance id=${instance.id} (${e.message})")
            throw ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, guidance)
        } catch (_: Exception) {
            val guidance = "Could not execute installer (job $jobId). Check the instance Java path, " +
                "executable permissions, and Java compatibility, then retry."
            logger.error("$guidance Instance id=${instance.id}")
            throw ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, guidance)
        }

        if (exitCode != 0) {
            val guidance = "Installer exited with code $exitCode (job $jobId). " +
                "Last captured output: ${safeExcerpt(jobId)} " +
                "Next action: check the instance Java version and the backend log for the full installer output, then retry."
            logger.error("Installer exited with code $exitCode for instance id=${instance.id} ($guidance)")
            throw ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, guidance)
        }

        logger.info("Installer completed successfully for instance id=${instance.id} (job $jobId)")
    }

    /**
     * Job id for one installer run: the known instance id plus a fresh short
     * run id, so the runner's per-job capture stays attributable and even
     * repeated runs of the same instance cannot mix their outputs. The id is
     * safe to show in error messages; it contains no secrets.
     */
    private fun installJobId(instance: Instance): String =
        "${instance.id ?: "unregistered"}-${UUID.randomUUID().toString().take(8)}"

    /**
     * Builds the short, guided output excerpt for a failure message from the
     * runner's per-job capture. Installer output is untrusted for display: it
     * regularly contains absolute paths and download URLs, so those are
     * replaced before the excerpt reaches a response. Each line and the whole
     * excerpt stay short; the full output remains in the backend log.
     */
    private fun safeExcerpt(jobId: String): String {
        val lines = installerCommandRunner.recentOutput(jobId, MAX_EXCERPT_LINES)
        if (lines.isEmpty()) return "(no installer output was captured)."
        val sanitized = lines.map { line ->
            var result = line
                .replace(URL_PATTERN, "<link removed>")
                .replace(WINDOWS_PATH_PATTERN, "<path removed>")
                .replace(UNIX_PATH_PATTERN, "<path removed>")
            if (result.length > MAX_EXCERPT_LINE_CHARS) {
                result = result.take(MAX_EXCERPT_LINE_CHARS) + "..."
            }
            result
        }
        return sanitized.joinToString(separator = " | ", prefix = "[", postfix = "].")
    }

    private fun buildInstallerCommand(instance: Instance, xmx: String, xms: String): List<String> {
        val base = mutableListOf(
            instance.javaPath?.takeIf { it.isNotBlank() } ?: "java",
            "-Xmx$xmx",
            "-Xms$xms",
            "-jar",
            INSTALLER_FILENAME,
        )
        when (instance.modLoader) {
            ModLoader.FORGE, ModLoader.NEOFORGE -> base += "--installServer"
            ModLoader.FABRIC, ModLoader.QUILT -> base += "nogui"
            // The vanilla server jar is prepared without an installer run; this
            // branch must stay unreachable from downloadInstaller.
            ModLoader.VANILLA, null -> throw IllegalStateException(
                "The vanilla server jar does not use an installer run"
            )
        }
        return base
    }

    private fun resolveJvmMemory(instance: Instance): Pair<String, String> {
        val settings = serverSettingsService.getServerSettings()
        val xmx = instance.javaXmx?.takeIf { it.isNotBlank() }
            ?: settings.defaultJavaXmx?.takeIf { it.isNotBlank() }
            ?: ServerSettingsService.DEFAULT_JAVA_XMX
        val xms = instance.javaXms?.takeIf { it.isNotBlank() }
            ?: settings.defaultJavaXms?.takeIf { it.isNotBlank() }
            ?: ServerSettingsService.DEFAULT_JAVA_XMS
        return xmx to xms
    }

    companion object {
        const val LOADER_INSTALLER_ARTIFACT = "loader-installer"
        const val VANILLA_SERVER_ARTIFACT = "vanilla-server-jar"
        private const val INSTALLER_FILENAME = "server-installer.jar"
        private const val VANILLA_SERVER_FILENAME = "server.jar"

        /** Lines of installer output shown in a failure message. */
        private const val MAX_EXCERPT_LINES = 8

        /** Upper length of one excerpt line before it is cut defensively. */
        private const val MAX_EXCERPT_LINE_CHARS = 200

        /** Any scheme URL; masked because URLs can embed credentials or tokens. */
        private val URL_PATTERN = Regex("[A-Za-z][A-Za-z0-9+.-]*://\\S+")

        /** Windows drive paths (C:\\...); masked before the Unix path rule. */
        private val WINDOWS_PATH_PATTERN = Regex("(?i)[A-Za-z]:\\\\\\S*")

        /**
         * Absolute Unix paths; relative paths stay visible because they carry
         * no sensitive location. The lookbehind keeps mid-word slashes (for
         * example version numbers or "and/or") untouched.
         */
        private val UNIX_PATH_PATTERN = Regex("(?<![A-Za-z0-9_.:])/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*")
    }
}

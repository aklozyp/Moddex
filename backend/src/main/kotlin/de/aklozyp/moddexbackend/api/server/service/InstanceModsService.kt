package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.dto.ModrinthProject
import de.aklozyp.moddexbackend.model.dto.ModrinthVersion
import de.aklozyp.moddexbackend.model.enums.ModDataProvider
import de.aklozyp.moddexbackend.model.enums.toModrinthLoaderId
import de.aklozyp.moddexbackend.model.mods.InstanceModList
import de.aklozyp.moddexbackend.model.mods.InstalledMod
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.util.UUID

@Service
class InstanceModsService(
    private val instanceService: InstanceService,
    private val modListStore: InstanceModListStore,
    private val modMarketplaceService: ModMarketplaceService,
    private val logger: Logger,
) {

    fun listInstalledMods(instanceId: UUID): List<InstalledMod> {
        val instanceDir = instanceService.getInstancePath(instanceId)
        val modList = modListStore.ensure(instanceDir, instanceId)
        return modList.mods.sortedBy { it.displayName ?: it.projectSlug ?: it.projectId }
    }

    fun installMod(
        instanceId: UUID,
        projectIdentifier: String,
        versionId: String?,
        provider: ModDataProvider?,
    ): List<InstalledMod> {
        val instance = instanceService.getInstanceById(instanceId)
        val instanceDir = instanceService.getInstancePath(instanceId)
        val modList = modListStore.ensure(instanceDir, instanceId)
        val visited = mutableSetOf<String>()
        val installed = mutableListOf<InstalledMod>()

        val activeProvider = provider ?: modMarketplaceService.activeProvider()
        installProjectRecursive(
            instance = instance,
            instanceDir = instanceDir,
            modList = modList,
            projectIdentifier = projectIdentifier,
            requestedVersionId = versionId,
            provider = activeProvider,
            visitedProjects = visited,
            installed = installed,
        )

        return installed
    }

    fun removeMod(instanceId: UUID, projectIdentifier: String): InstalledMod {
        val instanceDir = instanceService.getInstancePath(instanceId)
        val modList = modListStore.ensure(instanceDir, instanceId)
        val match = modList.mods.firstOrNull {
            it.projectId.equals(projectIdentifier, ignoreCase = true) ||
                it.projectSlug?.equals(projectIdentifier, ignoreCase = true) == true ||
                it.versionId.equals(projectIdentifier, ignoreCase = true)
        } ?: throw ResponseStatusException(HttpStatus.NOT_FOUND, "Mod '$projectIdentifier' is not installed")

        val modsDir = instanceDir.resolve(InstanceModListStore.MODS_DIR_NAME)
        match.fileName?.let { fileName ->
            runCatching {
                Files.deleteIfExists(modsDir.resolve(fileName))
            }.onFailure {
                logger.warn("Failed to delete mod file $fileName for instance id=$instanceId: ${it.message}")
            }
        }

        modList.mods.removeIf { it.projectId.equals(match.projectId, ignoreCase = true) }
        modListStore.save(instanceDir, modList)
        logger.info("Removed mod ${match.projectId} from instance id=$instanceId")
        return match
    }

    private fun installProjectRecursive(
        instance: Instance,
        instanceDir: Path,
        modList: InstanceModList,
        projectIdentifier: String,
        requestedVersionId: String?,
        provider: ModDataProvider,
        visitedProjects: MutableSet<String>,
        installed: MutableList<InstalledMod>,
    ) {
        val project = resolveProject(projectIdentifier, provider)
        val projectId = project.id
        if (!visitedProjects.add(projectId)) {
            logger.debug("Skipping already processed project $projectId during installation chain")
            return
        }

        val loaderId = instance.modLoader?.toModrinthLoaderId()
        val gameVersion = instance.gameVersion
        val version = resolveVersion(projectId, project.slug, requestedVersionId, loaderId, gameVersion, provider)

        validateCompatibility(instance, version, provider)

        val requiredDependencies = version.dependencies
            .filter { it.dependency_type.equals("required", ignoreCase = true) }

        for (dependency in requiredDependencies) {
            val depProjectId = dependency.project_id ?: dependency.version_id?.let { versionId ->
                runCatching { modMarketplaceService.getVersion(versionId, provider).project_id }
                    .onFailure { error ->
                        logger.warn("Failed to resolve dependency version ${dependency.version_id}: ${error.message}")
                    }
                    .getOrNull()
            }
            if (depProjectId.isNullOrBlank()) {
                logger.warn("Skipping dependency without reference for project $projectId")
                continue
            }
            val alreadyInstalled = modList.mods.any { it.projectId.equals(depProjectId, ignoreCase = true) }
            if (alreadyInstalled) {
                logger.debug("Dependency $depProjectId already installed; skipping")
                continue
            }
            installProjectRecursive(
                instance = instance,
                instanceDir = instanceDir,
                modList = modList,
                projectIdentifier = depProjectId,
                requestedVersionId = dependency.version_id,
                provider = provider,
                visitedProjects = visitedProjects,
                installed = installed,
            )
        }

        val clientOnly = isClientSideOnly(project, provider)
        val installedMod = installVersion(
            instanceDir = instanceDir,
            modList = modList,
            projectId = projectId,
            projectSlug = project.slug,
            version = version,
            provider = provider,
            shouldDownload = !clientOnly,
            clientSideOnly = clientOnly,
        )
        installedMod?.let(installed::add)
    }

    private fun resolveProject(projectIdentifier: String, provider: ModDataProvider): ModrinthProject =
        runCatching { modMarketplaceService.getProject(projectIdentifier, provider) }
            .getOrElse {
                val message = when (provider) {
                    ModDataProvider.MODRINTH -> "Project '$projectIdentifier' not found on Modrinth"
                    ModDataProvider.CURSEFORGE -> "Project '$projectIdentifier' not found on CurseForge"
                }
                throw ResponseStatusException(HttpStatus.NOT_FOUND, message, it)
            }

    private fun resolveVersion(
        projectId: String,
        projectSlug: String?,
        requestedVersionId: String?,
        loaderId: String?,
        gameVersion: String?,
        provider: ModDataProvider,
    ): ModrinthVersion {
        if (!requestedVersionId.isNullOrBlank()) {
            val version = modMarketplaceService.getVersion(requestedVersionId, provider)
            if (!version.project_id.equals(projectId, ignoreCase = true) && version.project_id.isNotBlank()) {
                logger.warn("Requested version ${version.id} does not match project $projectId (actual ${version.project_id})")
            }
            return version
        }

        val versions = modMarketplaceService.getProjectVersions(projectId, loaderId, gameVersion, provider)
        return versions.firstOrNull() ?: throw ResponseStatusException(
            HttpStatus.NOT_FOUND,
            "No compatible versions found for project ${projectSlug ?: projectId}"
        )
    }

    private fun validateCompatibility(instance: Instance, version: ModrinthVersion, provider: ModDataProvider) {
        if (provider == ModDataProvider.CURSEFORGE) {
            // CurseForge responses are already filtered by loader/version; metadata does not expose loader info reliably.
            return
        }

        val loaderId = instance.modLoader?.toModrinthLoaderId()
        if (!loaderId.isNullOrBlank()) {
            val matchesLoader = version.loaders.any { it.equals(loaderId, ignoreCase = true) }
            if (!matchesLoader) {
                throw ResponseStatusException(
                    HttpStatus.BAD_REQUEST,
                    "Version ${version.version_number} is not compatible with loader ${instance.modLoader}"
                )
            }
        }
        val gameVersion = instance.gameVersion
        if (!gameVersion.isNullOrBlank()) {
            val matchesGameVersion = version.game_versions.any { it.equals(gameVersion, ignoreCase = true) }
            if (!matchesGameVersion) {
                throw ResponseStatusException(
                    HttpStatus.BAD_REQUEST,
                    "Version ${version.version_number} does not target Minecraft version $gameVersion"
                )
            }
        }
    }

    private fun installVersion(
        instanceDir: Path,
        modList: InstanceModList,
        projectId: String,
        projectSlug: String?,
        version: ModrinthVersion,
        provider: ModDataProvider,
        shouldDownload: Boolean,
        clientSideOnly: Boolean,
    ): InstalledMod? {
        val modsDir = modListStore.modsDirectory(instanceDir)
        val targetFileInfo = version.files.firstOrNull { it.primary == true } ?: version.files.firstOrNull()
        val existing = modList.mods.firstOrNull { it.projectId.equals(projectId, ignoreCase = true) }

        if (existing != null && existing.versionId.equals(version.id, ignoreCase = true)) {
            logger.info("Mod ${projectSlug ?: projectId} already installed with version ${version.version_number}")
            if (shouldDownload && targetFileInfo != null) {
                val existingPath = modsDir.resolve(existing.fileName ?: targetFileInfo.filename)
                if (!Files.exists(existingPath)) {
                    downloadFile(targetFileInfo.url, existingPath, projectId, provider)
                }
            }
            return null
        }

        existing?.let {
            it.fileName?.let { fileName ->
                val existingPath = modsDir.resolve(fileName)
                runCatching { Files.deleteIfExists(existingPath) }
                    .onFailure { error -> logger.warn("Failed to remove previous file $fileName for project $projectId: ${error.message}") }
            }
            modList.mods.removeIf { mod -> mod.projectId.equals(projectId, ignoreCase = true) }
        }

        var downloadedFileName: String? = null
        var downloadUrl: String? = null
        var size: Long? = null
        var sha1: String? = null
        var sha512: String? = null

        if (shouldDownload) {
            val fileInfo = targetFileInfo ?: throw ResponseStatusException(
                HttpStatus.BAD_REQUEST,
                "Version ${version.version_number} has no downloadable files"
            )
            if (fileInfo.url.isBlank()) {
                throw ResponseStatusException(
                    HttpStatus.BAD_GATEWAY,
                    "Provider ${provider.name.lowercase()} did not provide a download URL for ${projectSlug ?: projectId}"
                )
            }
            val targetPath = modsDir.resolve(fileInfo.filename)
            downloadFile(fileInfo.url, targetPath, projectId, provider)
            downloadedFileName = fileInfo.filename
            downloadUrl = fileInfo.url
            size = fileInfo.size
            sha1 = fileInfo.hashes?.get("sha1")
            sha512 = fileInfo.hashes?.get("sha512")
        } else {
            logger.info("Skipping download for client-only mod ${projectSlug ?: projectId}")
            downloadedFileName = targetFileInfo?.filename
            downloadUrl = targetFileInfo?.url
            size = targetFileInfo?.size
            sha1 = targetFileInfo?.hashes?.get("sha1")
            sha512 = targetFileInfo?.hashes?.get("sha512")
        }

        val installed = InstalledMod(
            projectId = projectId,
            projectSlug = projectSlug,
            versionId = version.id,
            versionNumber = version.version_number,
            fileName = downloadedFileName,
            displayName = version.name,
            downloadUrl = downloadUrl,
            sha1 = sha1,
            sha512 = sha512,
            size = size,
            installedAt = Instant.now().toString(),
            dependencies = version.dependencies
                .filter { it.dependency_type.equals("required", ignoreCase = true) }
                .mapNotNull { it.project_id ?: it.version_id },
            provider = provider,
            downloaded = shouldDownload,
            clientSideOnly = clientSideOnly,
        )

        modList.mods.add(installed)
        modListStore.save(instanceDir, modList)
        logger.info("Installed mod ${projectSlug ?: projectId} version ${version.version_number} (provider=${provider.name})")
        return installed
    }

    private fun downloadFile(url: String, targetPath: Path, projectId: String, provider: ModDataProvider) {
        runCatching {
            Files.createDirectories(targetPath.parent)
            val connection = URI(url).toURL().openConnection().apply {
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
            }
            connection.getInputStream().use { input ->
                Files.copy(input, targetPath, StandardCopyOption.REPLACE_EXISTING)
            }
        }.onFailure { error ->
            val message = "Failed to download mod file for project $projectId from ${provider.name.lowercase()}: ${error.message}"
            logger.error(message)
            throw ResponseStatusException(
                HttpStatus.BAD_GATEWAY,
                message,
                error
            )
        }
    }

    private fun isClientSideOnly(project: ModrinthProject, provider: ModDataProvider): Boolean {
        if (provider != ModDataProvider.MODRINTH) {
            return false
        }
        val serverSupport = project.server_side?.lowercase()
        return serverSupport == "unsupported" || serverSupport == "false"
    }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 30_000
    }
}


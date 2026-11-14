package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.api.modrinth.ModrinthService
import de.aklozyp.moddexbackend.model.dto.ModrinthFiltersResponse
import de.aklozyp.moddexbackend.model.dto.ModrinthProject
import de.aklozyp.moddexbackend.model.dto.ModrinthProjectDetailsResponse
import de.aklozyp.moddexbackend.model.dto.ModrinthSearchResponse
import de.aklozyp.moddexbackend.model.dto.ModrinthVersion
import de.aklozyp.moddexbackend.model.enums.ModDataProvider
import org.springframework.stereotype.Service

@Service
class ModMarketplaceService(
    private val serverSettingsService: ServerSettingsService,
    private val modrinthService: ModrinthService,
) {

    fun activeProvider(): ModDataProvider =
        serverSettingsService.getServerSettings().modProvider ?: ModDataProvider.MODRINTH

    fun searchMods(
        query: String?,
        loaderId: String?,
        gameVersion: String?,
        categories: Collection<String>,
        limit: Int,
        offset: Int,
        index: String,
    ): ModrinthSearchResponse {
        if (activeProvider() == ModDataProvider.CURSEFORGE) {
            throw NotImplementedError("CurseForge is not supported in this version.")
        }
        return modrinthService.searchMods(query, loaderId, gameVersion, categories, limit, offset, index)
    }

    fun recommendedMods(
        loaderId: String?,
        gameVersion: String?,
        categories: Collection<String>,
        limit: Int,
        offset: Int,
        index: String,
    ): ModrinthSearchResponse {
        if (activeProvider() == ModDataProvider.CURSEFORGE) {
            throw NotImplementedError("CurseForge is not supported in this version.")
        }
        return modrinthService.searchMods(null, loaderId, gameVersion, categories, limit, offset, index)
    }

    fun getProjectDetails(
        projectId: String,
        loaderId: String?,
        gameVersion: String?,
        providerOverride: ModDataProvider? = null,
    ): ModrinthProjectDetailsResponse {
        val provider = providerOverride ?: activeProvider()
        if (provider == ModDataProvider.CURSEFORGE) {
            throw NotImplementedError("CurseForge is not supported in this version.")
        }
        return ModrinthProjectDetailsResponse(
            project = modrinthService.getProject(projectId),
            versions = modrinthService.getProjectVersions(projectId, loaderId, gameVersion),
            provider = ModDataProvider.MODRINTH,
        )
    }

    fun getProject(
        projectId: String,
        provider: ModDataProvider?,
    ): ModrinthProject {
        val activeProvider = provider ?: activeProvider()
        if (activeProvider == ModDataProvider.CURSEFORGE) {
            throw NotImplementedError("CurseForge is not supported in this version.")
        }
        return modrinthService.getProject(projectId)
    }

    fun getProjectVersions(
        projectId: String,
        loaderId: String?,
        gameVersion: String?,
        provider: ModDataProvider?,
    ): List<ModrinthVersion> {
        val activeProvider = provider ?: activeProvider()
        if (activeProvider == ModDataProvider.CURSEFORGE) {
            throw NotImplementedError("CurseForge is not supported in this version.")
        }
        return modrinthService.getProjectVersions(projectId, loaderId, gameVersion)
    }

    fun getVersion(versionId: String, provider: ModDataProvider?): ModrinthVersion {
        val activeProvider = provider ?: activeProvider()
        if (activeProvider == ModDataProvider.CURSEFORGE) {
            throw NotImplementedError("CurseForge is not supported in this version.")
        }
        return modrinthService.getVersion(versionId)
    }

    fun getFilters(): ModrinthFiltersResponse {
        if (activeProvider() == ModDataProvider.CURSEFORGE) {
            throw NotImplementedError("CurseForge is not supported in this version.")
        }
        val categories = modrinthService.listCategories()
            .filter { it.project_type.equals("mod", ignoreCase = true) }
            .sortedBy { it.name }
        return ModrinthFiltersResponse(
            loaders = modrinthService.listLoaders(),
            gameVersions = modrinthService.listGameVersions(),
            categories = categories,
        )
    }
}

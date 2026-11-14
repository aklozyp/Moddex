package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.InstanceService
import de.aklozyp.moddexbackend.api.server.service.ModMarketplaceService
import de.aklozyp.moddexbackend.model.dto.ModrinthProjectDetailsResponse
import de.aklozyp.moddexbackend.model.dto.ModrinthSearchResponse
import de.aklozyp.moddexbackend.model.enums.toModrinthLoaderId
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import java.util.UUID

@RestController
@RequestMapping("api/v1/instance/{instanceId}/modrinth")
class InstanceModrinthController(
    private val instanceService: InstanceService,
    private val modMarketplaceService: ModMarketplaceService,
    private val logger: Logger,
) {

    @GetMapping("/search")
    fun search(
        @PathVariable instanceId: UUID,
        @RequestParam(required = false) query: String?,
        @RequestParam(defaultValue = "relevance") index: String,
        @RequestParam(defaultValue = "20") limit: Int,
        @RequestParam(defaultValue = "0") offset: Int,
        @RequestParam(required = false) categories: List<String>?
    ): ModrinthSearchResponse {
        val instance = instanceService.getInstanceById(instanceId)
        val loaderId = instance.modLoader?.toModrinthLoaderId()
        val normalizedCategories = normalizeCategories(categories)
        val clampedLimit = limit.coerceIn(1, 100)
        val clampedOffset = offset.coerceAtLeast(0)
        logger.info("GET /api/v1/instance/$instanceId/modrinth/search query='${query ?: ""}' limit=$clampedLimit offset=$clampedOffset")
        return modMarketplaceService.searchMods(
            query = query,
            loaderId = loaderId,
            gameVersion = instance.gameVersion,
            categories = normalizedCategories,
            limit = clampedLimit,
            offset = clampedOffset,
            index = index
        )
    }

    @GetMapping("/recommended")
    fun recommended(
        @PathVariable instanceId: UUID,
        @RequestParam(defaultValue = "downloads") index: String,
        @RequestParam(defaultValue = "10") limit: Int,
        @RequestParam(defaultValue = "0") offset: Int,
        @RequestParam(required = false) categories: List<String>?
    ): ModrinthSearchResponse {
        val instance = instanceService.getInstanceById(instanceId)
        val loaderId = instance.modLoader?.toModrinthLoaderId()
        val normalizedCategories = normalizeCategories(categories)
        val clampedLimit = limit.coerceIn(1, 50)
        val clampedOffset = offset.coerceAtLeast(0)
        logger.info("GET /api/v1/instance/$instanceId/modrinth/recommended limit=$clampedLimit offset=$clampedOffset")
        val normalizedIndex = index.ifBlank { "downloads" }
        return modMarketplaceService.recommendedMods(
            loaderId = loaderId,
            gameVersion = instance.gameVersion,
            categories = normalizedCategories,
            limit = clampedLimit,
            offset = clampedOffset,
            index = normalizedIndex
        )
    }

    @GetMapping("/projects/{projectId}")
    fun projectDetails(
        @PathVariable instanceId: UUID,
        @PathVariable projectId: String
    ): ModrinthProjectDetailsResponse {
        val instance = instanceService.getInstanceById(instanceId)
        val loaderId = instance.modLoader?.toModrinthLoaderId()
        logger.info("GET /api/v1/instance/$instanceId/modrinth/projects/$projectId requested")
        return modMarketplaceService.getProjectDetails(projectId, loaderId, instance.gameVersion)
    }

    private fun normalizeCategories(categories: List<String>?): List<String> =
        categories?.flatMap { it.split(',') }
            ?.map { it.trim() }
            ?.filter { it.isNotBlank() }
            ?.distinct()
            ?: emptyList()
}


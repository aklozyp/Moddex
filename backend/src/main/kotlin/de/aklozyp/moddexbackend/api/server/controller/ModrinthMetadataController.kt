package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.ModMarketplaceService
import de.aklozyp.moddexbackend.model.dto.ModrinthFiltersResponse
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("api/v1/modrinth")
class ModrinthMetadataController(
    private val modMarketplaceService: ModMarketplaceService,
    private val logger: Logger,
) {

    @GetMapping("/filters")
    fun filters(): ModrinthFiltersResponse {
        logger.info("GET /api/v1/modrinth/filters requested")
        return modMarketplaceService.getFilters()
    }
}

package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.InstanceModsService
import de.aklozyp.moddexbackend.model.dto.InstallModRequest
import de.aklozyp.moddexbackend.model.dto.InstallModResponse
import de.aklozyp.moddexbackend.model.mods.InstalledMod
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.web.bind.annotation.DeleteMapping
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException
import java.util.UUID

@RestController
@RequestMapping("api/v1/instance/{instanceId}/mods")
class InstanceModsController(
    private val instanceModsService: InstanceModsService,
    private val logger: Logger,
) {

    @GetMapping
    fun listInstalledMods(@PathVariable instanceId: UUID): List<InstalledMod> {
        logger.info("GET /api/v1/instance/$instanceId/mods requested")
        return instanceModsService.listInstalledMods(instanceId)
    }

    @PostMapping
    fun installMod(
        @PathVariable instanceId: UUID,
        @RequestBody request: InstallModRequest,
    ): InstallModResponse {
        logger.info("POST /api/v1/instance/$instanceId/mods installing projectId='${request.projectId}' versionId='${request.versionId ?: "latest"}'")
        if (request.projectId.isBlank()) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "projectId must not be blank")
        }
        val installed = instanceModsService.installMod(instanceId, request.projectId, request.versionId, request.provider)
        logger.info("POST /api/v1/instance/$instanceId/mods installed ${installed.size} artifacts (including dependencies)")
        return InstallModResponse(installed = installed)
    }

    @DeleteMapping("/{identifier}")
    fun removeMod(@PathVariable instanceId: UUID, @PathVariable identifier: String): InstalledMod {
        logger.info("DELETE /api/v1/instance/$instanceId/mods/$identifier requested")
        val removed = instanceModsService.removeMod(instanceId, identifier)
        logger.info("DELETE /api/v1/instance/$instanceId/mods/$identifier removed mod")
        return removed
    }
}



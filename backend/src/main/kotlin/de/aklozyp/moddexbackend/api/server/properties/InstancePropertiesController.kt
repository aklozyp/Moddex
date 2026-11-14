package de.aklozyp.moddexbackend.api.server.properties

import de.aklozyp.moddexbackend.api.server.service.InstanceService
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.dto.InstanceBootstrapResponse
import de.aklozyp.moddexbackend.model.dto.ServerPropertiesDto
import de.aklozyp.moddexbackend.model.dto.ServerPropertiesUpdateRequest
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.PutMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException
import java.util.UUID

@RestController
@RequestMapping("/api/v1/instance")
class InstancePropertiesController(
    private val instanceService: InstanceService,
    private val serverPropertiesService: ServerPropertiesService,
    private val logger: Logger,
) {
    @PostMapping("/bootstrap")
    fun bootstrapInstance(@RequestBody body: Instance): InstanceBootstrapResponse {
        logger.info("POST /api/v1/instance/bootstrap requested for name='${body.name ?: "unnamed"}'")
        val created = instanceService.createAndInstallInstance(body)
        val id = created.id ?: run {
            logger.error("Instance creation did not return an id")
            throw ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "Instance creation failed without id")
        }
        // The instance itself is already created and persisted; a properties
        // hiccup must not surface as a misleading creation failure, because a
        // retry would create a duplicate instance. The server settings view of
        // the instance loads the properties again and reports problems there.
        val properties = try {
            serverPropertiesService.initializeForInstance(id)
            serverPropertiesService.loadProperties(id)
        } catch (ex: Exception) {
            logger.warn(
                "Instance id=$id was created, but the initial server.properties could not be prepared: " +
                    "${ex.message ?: ex.javaClass.simpleName}. Open the server settings of the instance to load them again."
            )
            ServerPropertiesDto(categories = emptyList())
        }
        logger.info("POST /api/v1/instance/bootstrap created instance id=$id")
        return InstanceBootstrapResponse(created, properties)
    }

    @GetMapping("/{id}/properties")
    fun getProperties(@PathVariable("id") id: UUID): ServerPropertiesDto {
        logger.info("GET /api/v1/instance/$id/properties requested")
        val dto = serverPropertiesService.loadProperties(id)
        logger.info("GET /api/v1/instance/$id/properties returned ${dto.categories.sumOf { it.entries.size }} entries")
        return dto
    }

    @GetMapping("/{id}/properties/backup")
    fun getBackupProperties(@PathVariable("id") id: UUID): ServerPropertiesDto {
        logger.info("GET /api/v1/instance/$id/properties/backup requested")
        val dto = serverPropertiesService.loadBackupProperties(id)
        logger.info("GET /api/v1/instance/$id/properties/backup returned ${dto.categories.sumOf { it.entries.size }} entries")
        return dto
    }

    @PutMapping("/{id}/properties")
    fun updateProperties(
        @PathVariable("id") id: UUID,
        @RequestBody request: ServerPropertiesUpdateRequest
    ): ServerPropertiesDto {
        logger.info("PUT /api/v1/instance/$id/properties updating ${request.values.size} entries")
        val dto = serverPropertiesService.updateProperties(id, request)
        logger.info("PUT /api/v1/instance/$id/properties update completed")
        return dto
    }

    @PostMapping("/{id}/properties/reset")
    fun resetProperties(@PathVariable("id") id: UUID): ServerPropertiesDto {
        logger.info("POST /api/v1/instance/$id/properties/reset requested")
        val dto = serverPropertiesService.resetProperties(id)
        logger.info("POST /api/v1/instance/$id/properties/reset completed")
        return dto
    }
}
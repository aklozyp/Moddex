package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.InstanceDeletionException
import de.aklozyp.moddexbackend.api.server.service.InstanceDeletionService
import de.aklozyp.moddexbackend.api.server.service.InstanceService
import de.aklozyp.moddexbackend.api.server.service.InstanceStillRunningException
import de.aklozyp.moddexbackend.api.server.service.ModpackExportService
import de.aklozyp.moddexbackend.api.server.service.ModpackFormat
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.core.io.ByteArrayResource
import org.springframework.http.HttpHeaders
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*
import java.util.UUID

@RequestMapping("api/v1/instance")
@RestController
class InstanceController(
    private val instanceService: InstanceService,
    private val instanceDeletionService: InstanceDeletionService,
    private val modpackExportService: ModpackExportService,
    private val logger: Logger,
) {
    @GetMapping
    fun getAllInstances(): List<Instance> {
        logger.info("GET /api/v1/instance requested")
        val instances = instanceService.getAllInstances()
        logger.info("GET /api/v1/instance returning ${instances.size} instances")
        return instances
    }

    @GetMapping("/{id}")
    fun getInstanceById(@PathVariable("id") id: UUID): Instance {
        logger.info("GET /api/v1/instance/$id requested")
        val instance = instanceService.getInstanceById(id)
        logger.info("GET /api/v1/instance/$id succeeded (name='${instance.name ?: "unnamed"}')")
        return instance
    }

    @PostMapping
    fun createInstance(@RequestBody instance: Instance): Instance {
        logger.info("POST /api/v1/instance creating instance name='${instance.name ?: "unnamed"}'")
        val created = instanceService.createAndInstallInstance(instance)
        logger.info("POST /api/v1/instance created instance with id=${created.id}")
        return created
    }

    @PutMapping("/{id}")
    fun updateInstanceById(@PathVariable id: UUID, @RequestBody instance: Instance): Instance {
        logger.info("PUT /api/v1/instance/$id updating instance")
        val updated = instanceService.updateInstanceById(id, instance)
        logger.info("PUT /api/v1/instance/$id update succeeded")
        return updated
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    fun deleteInstanceById(@PathVariable id: UUID) {
        logger.info("DELETE /api/v1/instance/$id requested")
        instanceDeletionService.deleteInstanceById(id)
        logger.info("DELETE /api/v1/instance/$id completed")
    }

    @ExceptionHandler(InstanceDeletionException::class)
    fun handleInstanceDeletionFailure(exception: InstanceDeletionException): ResponseEntity<Any> {
        logger.error("DELETE /api/v1/instance failed partially: ${exception.message} Remaining: ${exception.remainingPaths}")
        return ResponseEntity.internalServerError().body(
            mapOf(
                "error" to exception.message,
                "instanceDirectory" to exception.instanceDirectory,
                "remaining" to exception.remainingPaths,
            ),
        )
    }

    @ExceptionHandler(InstanceStillRunningException::class)
    fun handleInstanceStillRunning(exception: InstanceStillRunningException): ResponseEntity<Any> {
        logger.warn("DELETE /api/v1/instance blocked: ${exception.message}")
        return ResponseEntity.status(HttpStatus.CONFLICT).body(
            mapOf(
                "error" to exception.message,
                "errorKind" to InstanceErrorKind.INSTANCE_RUNNING.name,
            ),
        )
    }

    @GetMapping("/{id}/modpack")
    fun downloadModpack(
        @PathVariable id: UUID,
        @RequestParam(required = false, name = "format") formatRaw: String?,
    ): ResponseEntity<ByteArrayResource> {
        val format = ModpackFormat.from(formatRaw)
        logger.info("GET /api/v1/instance/$id/modpack requested (format=$format)")
        val archive = modpackExportService.export(id, format)

        val resource = ByteArrayResource(archive.bytes)
        return ResponseEntity.ok()
            .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"${archive.filename}\"")
            .contentType(MediaType.parseMediaType(archive.contentType))
            .contentLength(archive.bytes.size.toLong())
            .body(resource)
    }
}

enum class InstanceErrorKind {
    INSTANCE_RUNNING
}

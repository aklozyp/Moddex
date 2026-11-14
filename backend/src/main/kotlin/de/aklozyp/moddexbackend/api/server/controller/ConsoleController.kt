package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.EulaNotAcceptedException
import de.aklozyp.moddexbackend.api.server.service.ProcessManagerService
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*
import java.util.UUID

@RequestMapping("api/v1/instance/{id}/console")
@RestController
class ConsoleController(
    private val processManagerService: ProcessManagerService,
    private val logger: Logger
) {

    @PostMapping("/start")
    fun start(@PathVariable id: UUID): ResponseEntity<Map<String, String>> {
        return try {
            processManagerService.startInstance(id)
            ResponseEntity.ok(mapOf("message" to "Started"))
        } catch (e: EulaNotAcceptedException) {
            logger.error("Failed to start instance $id: ${e.message}")
            ResponseEntity.badRequest().body(
                mapOf(
                    "error" to (e.message ?: "Unknown error"),
                    "errorKind" to ConsoleErrorKind.EULA_NOT_ACCEPTED.name
                )
            )
        } catch (e: Exception) {
            logger.error("Failed to start instance $id: ${e.message}")
            ResponseEntity.badRequest().body(mapOf("error" to (e.message ?: "Unknown error")))
        }
    }

    @PostMapping("/stop")
    fun stop(@PathVariable id: UUID): ResponseEntity<Map<String, String>> {
        processManagerService.stopInstance(id)
        return ResponseEntity.ok(mapOf("message" to "Stop command sent"))
    }

    @PostMapping("/kill")
    fun kill(@PathVariable id: UUID): ResponseEntity<Map<String, String>> {
        processManagerService.killInstance(id)
        return ResponseEntity.ok(mapOf("message" to "Killed"))
    }

    @PostMapping("/command")
    fun command(@PathVariable id: UUID, @RequestBody command: CommandRequest): ResponseEntity<Map<String, String>> {
        processManagerService.sendCommand(id, command.command)
        return ResponseEntity.ok(mapOf("message" to "Sent"))
    }

    @GetMapping("/logs")
    fun getLogs(@PathVariable id: UUID): List<String> {
        return processManagerService.getLogs(id)
    }

    @GetMapping("/status")
    fun getStatus(@PathVariable id: UUID): StatusResponse {
        return StatusResponse(processManagerService.getStatus(id))
    }

    data class CommandRequest(val command: String)
    data class StatusResponse(val status: String)
}

enum class ConsoleErrorKind {
    EULA_NOT_ACCEPTED
}

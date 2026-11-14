package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.ServerSettingsPersistenceException
import de.aklozyp.moddexbackend.api.server.service.SetupAlreadyCompletedException
import de.aklozyp.moddexbackend.api.server.service.SetupBootstrapProofInvalidException
import de.aklozyp.moddexbackend.api.server.service.SetupService
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*

@RestController
@RequestMapping("api/v1/setup")
class SetupController(
    private val setupService: SetupService
) {

    @GetMapping("/status")
    fun getStatus(): Map<String, Boolean> {
        return mapOf("setupRequired" to setupService.isSetupRequired())
    }

    @PostMapping("/complete")
    fun completeSetup(@RequestBody request: SetupRequest): ResponseEntity<Any> {
        if (request.password.length < 8) {
             return ResponseEntity.badRequest().body(mapOf("error" to "Password must be at least 8 characters"))
        }

        return try {
            setupService.completeSetup(request.password, request.bootstrapToken)
            ResponseEntity.ok(mapOf("message" to "Setup completed"))
        } catch (_: SetupAlreadyCompletedException) {
            ResponseEntity.status(409).body(mapOf("error" to "Setup already completed"))
        } catch (e: SetupBootstrapProofInvalidException) {
            ResponseEntity.status(403).body(mapOf("error" to e.message))
        }
    }

    @ExceptionHandler(ServerSettingsPersistenceException::class)
    fun handlePersistenceFailure(exception: ServerSettingsPersistenceException): ResponseEntity<Any> {
        return ResponseEntity.internalServerError().body(mapOf("error" to exception.message))
    }

    data class SetupRequest(val password: String, val bootstrapToken: String? = null)
}

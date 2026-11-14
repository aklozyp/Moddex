package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.EulaService
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*
import java.util.UUID

@RequestMapping("api/v1/instance/{id}/eula")
@RestController
class EulaController(
    private val eulaService: EulaService
) {

    @GetMapping
    fun checkEula(@PathVariable id: UUID): ResponseEntity<Map<String, Boolean>> {
        val accepted = eulaService.isEulaAccepted(id)
        return ResponseEntity.ok(mapOf("accepted" to accepted))
    }

    @PostMapping("/accept")
    fun acceptEula(@PathVariable id: UUID): ResponseEntity<Map<String, String>> {
        eulaService.acceptEula(id)
        return ResponseEntity.ok(mapOf("message" to "EULA accepted"))
    }
}

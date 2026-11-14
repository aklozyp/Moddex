package de.aklozyp.moddexbackend.api.client

import de.aklozyp.moddexbackend.api.client.service.ClientSettingsService
import de.aklozyp.moddexbackend.model.ClientSettings
import de.aklozyp.moddexbackend.model.dto.ClientSettingsDto
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/v1/client")
class ClientSettingsController(
    private val clientSettingsService: ClientSettingsService,
    private val logger: Logger,
) {
    @GetMapping("/settings")
    fun getSettings(): ResponseEntity<ClientSettingsDto> {
        logger.info("GET /api/client/settings requested")
        val settings = clientSettingsService.getSettings()
        logger.info("GET /api/client/settings returning webTheme='${settings.webTheme}'")
        return ResponseEntity.ok(settings.toDto())
    }

    @PostMapping("/settings")
    fun updateSettings(@RequestBody body: ClientSettingsDto): ResponseEntity<ClientSettingsDto> {
        logger.info("POST /api/client/settings updating webTheme='${body.webTheme ?: "<default>"}'")
        val updated = clientSettingsService.updateSettings(body.webTheme)
        logger.info("POST /api/client/settings update persisted webTheme='${updated.webTheme}'")
        return ResponseEntity.ok(updated.toDto())
    }

    private fun ClientSettings.toDto() = ClientSettingsDto(
        webTheme = this.webTheme
    )
}

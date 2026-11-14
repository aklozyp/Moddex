package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.ServerSettingsService
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PutMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RequestMapping("/api/v1/serverSettings")
@RestController
class ServerSettingsController(
    private val serverSettingsService: ServerSettingsService,
    private val logger: Logger,
) {
    @GetMapping
    fun getServerSettings(): ServerSettings {
        logger.info("GET /api/v1/serverSettings requested")
        val settings = serverSettingsService.getServerSettings()
        logger.info("GET /api/v1/serverSettings returning projectPath='${settings.projectPath ?: "<unset>"}'")
        return settings
    }

    @PutMapping
    fun updateServerSettings(@RequestBody serverSettings: ServerSettings): ServerSettings {
        logger.info("PUT /api/v1/serverSettings updating projectPath='${serverSettings.projectPath ?: "<unset>"}'")
        val updated = serverSettingsService.updateServerSettings(serverSettings)
        logger.info("PUT /api/v1/serverSettings update persisted projectPath='${updated.projectPath ?: "<unset>"}'")
        return updated
    }
}

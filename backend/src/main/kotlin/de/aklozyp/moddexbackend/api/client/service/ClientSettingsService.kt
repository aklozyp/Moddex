package de.aklozyp.moddexbackend.api.client.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.ClientSettings
import de.aklozyp.moddexbackend.services.Logger
import jakarta.annotation.PostConstruct
import org.springframework.stereotype.Service
import java.nio.file.Files
import java.nio.file.Path

@Service
class ClientSettingsService(
    private val objectMapper: ObjectMapper,
    private val logger: Logger,
    private val directories: ModdexDirectories,
) {
    private val defaultSettings = ClientSettings()
    private val etcDir: Path
        get() = directories.configDir
    private val settingsFile: Path
        get() = etcDir.resolve("clientsettings.json")

    @PostConstruct
    fun init() {
        try {
            if (!Files.exists(etcDir)) {
                Files.createDirectories(etcDir)
                logger.info("Created client settings directory at ${etcDir.toAbsolutePath()}")
            }
        } catch (e: Exception) {
            logger.warn("Could not create ${etcDir.toAbsolutePath()}: ${e.message}")
        }

        if (!Files.exists(settingsFile)) {
            try {
                saveSettings(defaultSettings)
                logger.info("Initialized default client settings at ${settingsFile.toAbsolutePath()}")
            } catch (e: Exception) {
                logger.warn("Could not initialize client settings file: ${e.message}")
            }
        }
    }

    fun getSettings(): ClientSettings {
        return try {
            if (Files.exists(settingsFile)) {
                val settings = objectMapper.readValue<ClientSettings>(settingsFile.toFile())
                logger.info("Loaded client settings from ${settingsFile.toAbsolutePath()}")
                settings
            } else {
                logger.info("Client settings file missing; falling back to defaults")
                defaultSettings
            }
        } catch (e: Exception) {
            logger.error("Failed to read client settings: ${e.message}")
            defaultSettings
        }
    }

    fun updateSettings(webTheme: String?): ClientSettings {
        val current = getSettings()
        val merged = current.copy(
            webTheme = webTheme ?: current.webTheme
        )
        logger.info("Updating client settings to webTheme='${merged.webTheme}'")
        saveSettings(merged)
        return merged
    }

    private fun saveSettings(settings: ClientSettings) {
        try {
            Files.createDirectories(etcDir)
            objectMapper.writerWithDefaultPrettyPrinter().writeValue(settingsFile.toFile(), settings)
            logger.info("Saved ClientSettings to ${settingsFile.toAbsolutePath()}")
        } catch (e: Exception) {
            logger.error("Failed to write client settings: ${e.message}")
            throw e
        }
    }
}

package de.aklozyp.moddexbackend.api.client.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.ClientSettings
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.mockk
import io.mockk.verify
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path

class ClientSettingsServiceTest {

    @TempDir
    lateinit var tempDir: Path

    private lateinit var directories: ModdexDirectories
    private lateinit var service: ClientSettingsService

    private val objectMapper: ObjectMapper = jacksonObjectMapper()
    private val logger: Logger = mockk(relaxed = true)

    @BeforeEach
    fun setUp() {
        directories = object : ModdexDirectories {
            override val configDir: Path = tempDir.resolve("config")
            override val dataDir: Path = tempDir.resolve("data")
            override val logsDir: Path = tempDir.resolve("logs")
        }
        service = ClientSettingsService(objectMapper, logger, directories)
    }

    @Test
    fun initCreatesConfigDirectoryAndDefaultSettingsFile() {
        service.init()

        val settingsFile = directories.configDir.resolve("clientsettings.json")
        assertThat(Files.exists(settingsFile)).isTrue()
        val persisted = objectMapper.readValue(settingsFile.toFile(), ClientSettings::class.java)
        assertThat(persisted.webTheme).isEqualTo("light")
    }

    @Test
    fun updateSettingsPersistsAndReturnsMergedSettings() {
        service.init()

        val updated = service.updateSettings("dark")

        assertThat(updated.webTheme).isEqualTo("dark")
        val settingsFile = directories.configDir.resolve("clientsettings.json")
        val persisted = objectMapper.readValue(settingsFile.toFile(), ClientSettings::class.java)
        assertThat(persisted.webTheme).isEqualTo("dark")
        verify(atLeast = 1) { logger.info(match { it.contains("Updating client settings") }) }
    }

    @Test
    fun getSettingsFallsBackToDefaultWhenFileIsUnreadable() {
        Files.createDirectories(directories.configDir)
        Files.writeString(directories.configDir.resolve("clientsettings.json"), "{ invalid json")

        val settings = service.getSettings()

        assertThat(settings.webTheme).isEqualTo("light")
        verify { logger.error(match { it.contains("Failed to read client settings") }) }
    }
}

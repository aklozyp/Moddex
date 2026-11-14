package de.aklozyp.moddexbackend.api.client

import com.fasterxml.jackson.databind.ObjectMapper
import de.aklozyp.moddexbackend.model.ClientSettings
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.EnabledOnOs
import org.junit.jupiter.api.condition.OS
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.http.MediaType
import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.nio.file.Files
import java.nio.file.Path

@SpringBootTest
@AutoConfigureMockMvc
@Tag("ci")
@EnabledOnOs(OS.LINUX, OS.MAC)
class ClientSettingsControllerIT {

    @Autowired
    lateinit var mockMvc: MockMvc

    @Autowired
    lateinit var objectMapper: ObjectMapper

    @Test
    fun updateAndRetrieveClientSettingsThroughApi() {
        mockMvc.perform(
            post("/api/v1/client/settings")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"webTheme":"dark"}"""),
        ).andExpect(status().isOk)

        mockMvc.perform(get("/api/v1/client/settings"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.webTheme").value("dark"))

        val persisted = objectMapper.readValue(CONFIG_DIR.resolve("clientsettings.json").toFile(), ClientSettings::class.java)
        assertThat(persisted.webTheme).isEqualTo("dark")
    }

    companion object {
        private val CONFIG_DIR: Path = Files.createTempDirectory("moddex-config-it")
        private val DATA_DIR: Path = Files.createTempDirectory("moddex-data-it")

        @JvmStatic
        @DynamicPropertySource
        fun registerProperties(registry: DynamicPropertyRegistry) {
            registry.add("moddex.paths.config") { CONFIG_DIR.toString() }
            registry.add("moddex.paths.data") { DATA_DIR.toString() }
            registry.add("moddex.paths.logs") { DATA_DIR.resolve("logs").toString() }
        }
    }
}

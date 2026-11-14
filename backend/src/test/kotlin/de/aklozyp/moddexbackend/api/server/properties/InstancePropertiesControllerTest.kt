package de.aklozyp.moddexbackend.api.server.properties

import com.jayway.jsonpath.JsonPath
import de.aklozyp.moddexbackend.api.server.service.InstanceService
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.dto.ServerPropertiesDto
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.hamcrest.Matchers
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import java.io.IOException
import java.util.UUID

/**
 * Contract test for the instance creation response: the frontend consumes
 * exactly this response form (instance + initial server properties), so the
 * bootstrap endpoint must keep publishing it.
 */
class InstancePropertiesControllerTest {

    private val instanceService: InstanceService = mockk()
    private val serverPropertiesService: ServerPropertiesService = mockk()
    private val logger: Logger = mockk(relaxed = true)
    private val mockMvc = MockMvcBuilders.standaloneSetup(
        InstancePropertiesController(instanceService, serverPropertiesService, logger)
    ).build()

    @Test
    fun `bootstrap returns the created instance together with the initial server properties`() {
        val id = UUID.randomUUID()
        val created = Instance(
            id = id,
            name = "New Project",
            description = "described",
            gameVersion = "1.21.4",
            modLoader = ModLoader.VANILLA,
            modLoaderVersion = null,
            javaXmx = "4G",
            javaXms = "2G",
            javaPath = null,
        )
        val properties = ServerPropertiesDto(categories = emptyList())
        every { instanceService.createAndInstallInstance(any()) } returns created
        every { serverPropertiesService.initializeForInstance(id) } returns Unit
        every { serverPropertiesService.loadProperties(id) } returns properties

        val response = mockMvc.perform(
            post("/api/v1/instance/bootstrap")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"name":"New Project","gameVersion":"1.21.4"}""")
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.instance.id").value(id.toString()))
            .andExpect(jsonPath("$.instance.name").value("New Project"))
            .andExpect(jsonPath("$.instance.description").value("described"))
            .andExpect(jsonPath("$.instance.gameVersion").value("1.21.4"))
            .andExpect(jsonPath("$.instance.modLoader").value("VANILLA"))
            .andExpect(jsonPath("$.instance.modLoaderVersion").value(Matchers.nullValue()))
            .andExpect(jsonPath("$.instance.javaXmx").value("4G"))
            .andExpect(jsonPath("$.instance.javaXms").value("2G"))
            .andExpect(jsonPath("$.instance.javaPath").value(Matchers.nullValue()))
            .andExpect(jsonPath("$.serverProperties.categories").isArray)
            .andReturn()

        // The response carries exactly the two contract keys the frontend consumes.
        val top = JsonPath.read<Map<String, Any>>(response.response.contentAsString, "$")
        assertEquals(setOf("instance", "serverProperties"), top.keys)
    }

    @Test
    fun `bootstrap keeps the created instance when property initialization fails`() {
        val id = UUID.randomUUID()
        val created = Instance(id = id, name = "Kept Project", gameVersion = "1.21.4")
        every { instanceService.createAndInstallInstance(any()) } returns created
        every { serverPropertiesService.initializeForInstance(id) } throws IOException("properties template unreadable")

        mockMvc.perform(
            post("/api/v1/instance/bootstrap")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"name":"Kept Project","gameVersion":"1.21.4"}""")
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.instance.id").value(id.toString()))
            .andExpect(jsonPath("$.serverProperties.categories").isArray)

        verify { logger.warn(match { it.contains("server.properties") }) }
    }
}

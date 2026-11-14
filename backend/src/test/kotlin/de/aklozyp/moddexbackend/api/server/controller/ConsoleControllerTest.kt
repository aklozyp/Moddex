package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.EulaNotAcceptedException
import de.aklozyp.moddexbackend.api.server.service.ProcessManagerService
import de.aklozyp.moddexbackend.services.Logger
import org.junit.jupiter.api.Test
import org.mockito.Mockito
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.util.UUID

@WebMvcTest(ConsoleController::class)
@AutoConfigureMockMvc(addFilters = false)
class ConsoleControllerTest @Autowired constructor(
    private val mockMvc: MockMvc,
) {

    @MockBean
    private lateinit var processManagerService: ProcessManagerService

    @MockBean
    private lateinit var logger: Logger

    @Test
    fun `start returns stable EULA error kind alongside localized message`() {
        val instanceId = UUID.randomUUID()
        val localizedMessage = "Die Minecraft-EULA wurde noch nicht akzeptiert"
        Mockito.doThrow(EulaNotAcceptedException(localizedMessage))
            .`when`(processManagerService)
            .startInstance(instanceId)

        mockMvc.perform(post("/api/v1/instance/$instanceId/console/start"))
            .andExpect(status().isBadRequest)
            .andExpect(jsonPath("$.error").value(localizedMessage))
            .andExpect(jsonPath("$.errorKind").value("EULA_NOT_ACCEPTED"))
    }

    @Test
    fun `start keeps unrelated errors generic`() {
        val instanceId = UUID.randomUUID()
        Mockito.doThrow(IllegalStateException("Instance is already running"))
            .`when`(processManagerService)
            .startInstance(instanceId)

        mockMvc.perform(post("/api/v1/instance/$instanceId/console/start"))
            .andExpect(status().isBadRequest)
            .andExpect(jsonPath("$.error").value("Instance is already running"))
            .andExpect(jsonPath("$.errorKind").doesNotExist())
    }
}

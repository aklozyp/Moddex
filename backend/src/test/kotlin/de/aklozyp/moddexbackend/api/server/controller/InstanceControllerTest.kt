package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.InstanceDeletionException
import de.aklozyp.moddexbackend.api.server.service.InstanceDeletionService
import de.aklozyp.moddexbackend.api.server.service.InstanceService
import de.aklozyp.moddexbackend.api.server.service.InstanceStillRunningException
import de.aklozyp.moddexbackend.api.server.service.ModpackExportService
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.every
import io.mockk.mockk
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import java.util.UUID

class InstanceControllerTest {

    private lateinit var instanceService: InstanceService
    private lateinit var instanceDeletionService: InstanceDeletionService
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun setUp() {
        instanceService = mockk()
        instanceDeletionService = mockk()
        val modpackExportService = mockk<ModpackExportService>()
        val logger = mockk<Logger>(relaxed = true)
        mockMvc = MockMvcBuilders.standaloneSetup(
            InstanceController(instanceService, instanceDeletionService, modpackExportService, logger),
        ).build()
    }

    @Test
    fun deleteInstanceByIdReturnsNoContentOnSuccess() {
        val id = UUID.randomUUID()
        every { instanceDeletionService.deleteInstanceById(id) } returns Unit

        val result = mockMvc.perform(delete("/api/v1/instance/$id")).andReturn()

        assertThat(result.response.status).isEqualTo(204)
    }

    @Test
    fun deleteInstanceByIdReturnsConflictWhenInstanceIsStillRunning() {
        val id = UUID.randomUUID()
        every { instanceDeletionService.deleteInstanceById(id) } throws InstanceStillRunningException()

        val result = mockMvc.perform(delete("/api/v1/instance/$id")).andReturn()

        assertThat(result.response.status).isEqualTo(409)
        val body = result.response.contentAsString
        assertThat(body).contains("\"error\"")
        assertThat(body).contains("\"errorKind\"")
        assertThat(body).contains("INSTANCE_RUNNING")
        // The error names the safe next action instead of raw exception details.
        assertThat(body).contains("Stop the instance in the console")
        assertThat(body).contains("then retry the deletion")
        assertThat(body).contains("No instance data was changed")
    }

    @Test
    fun deleteInstanceByIdReturnsStructuredErrorWhenDeletionFailsPartially() {
        val id = UUID.randomUUID()
        every { instanceDeletionService.deleteInstanceById(id) } throws InstanceDeletionException(
            listOf("worlds/level.dat", "worlds"),
            "Locked",
        )

        val result = mockMvc.perform(delete("/api/v1/instance/$id")).andReturn()

        assertThat(result.response.status).isEqualTo(500)
        val body = result.response.contentAsString
        assertThat(body).contains("\"error\"")
        assertThat(body).contains("\"instanceDirectory\"")
        assertThat(body).contains("Locked")
        assertThat(body).contains("\"remaining\"")
        assertThat(body).contains("could not be fully deleted")
        assertThat(body).contains("worlds/level.dat")
        assertThat(body).contains("worlds")
    }

    @Test
    fun deleteInstanceByIdReturnsNotFoundWhenInstanceIsMissing() {
        val id = UUID.randomUUID()
        every { instanceDeletionService.deleteInstanceById(id) } throws
            org.springframework.web.server.ResponseStatusException(
                org.springframework.http.HttpStatus.NOT_FOUND,
                "Instance with id $id not found",
            )

        val result = mockMvc.perform(delete("/api/v1/instance/$id")).andReturn()

        assertThat(result.response.status).isEqualTo(404)
    }

    @Test
    fun deleteInstanceByIdErrorResponseUsesJsonContentType() {
        val id = UUID.randomUUID()
        every { instanceDeletionService.deleteInstanceById(id) } throws InstanceDeletionException(listOf("mods"), "Broken")

        val result = mockMvc.perform(delete("/api/v1/instance/$id")).andReturn()

        assertThat(result.response.status).isEqualTo(500)
        assertThat(result.response.contentType).contains(MediaType.APPLICATION_JSON_VALUE)
    }
}

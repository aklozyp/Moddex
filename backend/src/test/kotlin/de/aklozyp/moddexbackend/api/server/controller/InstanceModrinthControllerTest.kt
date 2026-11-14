package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.InstanceService
import de.aklozyp.moddexbackend.api.server.service.ModMarketplaceService
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.dto.ModrinthSearchHit
import de.aklozyp.moddexbackend.model.dto.ModrinthSearchResponse
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.services.Logger
import org.junit.jupiter.api.Test
import org.mockito.BDDMockito.given
import org.mockito.Mockito
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest
import org.springframework.boot.test.mock.mockito.MockBean
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status
import java.util.UUID

@WebMvcTest(InstanceModrinthController::class)
// Sicherheitsfilter (JWT) sind nicht Gegenstand dieses Controller-Tests
@AutoConfigureMockMvc(addFilters = false)
class InstanceModrinthControllerTest @Autowired constructor(
    private val mockMvc: MockMvc,
) {

    @MockBean
    private lateinit var instanceService: InstanceService

    @MockBean
    private lateinit var modMarketplaceService: ModMarketplaceService

    @MockBean
    private lateinit var logger: Logger

    @Test
    fun `recommended endpoint forwards loader categories and offset`() {
        val instanceId = UUID.randomUUID()
        val instance = Instance(id = instanceId, gameVersion = "1.20.1", modLoader = ModLoader.FABRIC)
        given(instanceService.getInstanceById(instanceId)).willReturn(instance)

        val expectedCategories = listOf("magic", "adventure")
        val response = searchResponse(offset = 10, limit = 5)

        Mockito.doReturn(response).`when`(modMarketplaceService).recommendedMods(
            loaderId = "fabric",
            gameVersion = "1.20.1",
            categories = expectedCategories,
            limit = 5,
            offset = 10,
            index = "downloads"
        )

        mockMvc.perform(
            get("/api/v1/instance/$instanceId/modrinth/recommended")
                .param("limit", "5")
                .param("offset", "10")
                .param("index", "downloads")
                .param("categories", "magic", "adventure")
                .accept(MediaType.APPLICATION_JSON)
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.total_hits").value(response.total_hits))
            .andExpect(jsonPath("$.offset").value(response.offset))
            .andExpect(jsonPath("$.hits[0].project_id").value("project-id"))

        Mockito.verify(modMarketplaceService).recommendedMods(
            loaderId = "fabric",
            gameVersion = "1.20.1",
            categories = expectedCategories,
            limit = 5,
            offset = 10,
            index = "downloads"
        )
    }

    @Test
    fun `search endpoint propagates query limit and offset`() {
        val instanceId = UUID.randomUUID()
        val instance = Instance(id = instanceId, gameVersion = "1.20.1", modLoader = ModLoader.FORGE)
        given(instanceService.getInstanceById(instanceId)).willReturn(instance)

        val response = searchResponse(offset = 50, limit = 25)

        Mockito.doReturn(response).`when`(modMarketplaceService).searchMods(
            query = "Create",
            loaderId = "forge",
            gameVersion = "1.20.1",
            categories = emptyList(),
            limit = 25,
            offset = 50,
            index = "downloads"
        )

        mockMvc.perform(
            get("/api/v1/instance/$instanceId/modrinth/search")
                .param("query", "Create")
                .param("limit", "25")
                .param("offset", "50")
                .param("index", "downloads")
                .accept(MediaType.APPLICATION_JSON)
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.hits[0].slug").value("project-slug"))
            .andExpect(jsonPath("$.limit").value(response.limit))
            .andExpect(jsonPath("$.offset").value(response.offset))

        Mockito.verify(modMarketplaceService).searchMods(
            query = "Create",
            loaderId = "forge",
            gameVersion = "1.20.1",
            categories = emptyList(),
            limit = 25,
            offset = 50,
            index = "downloads"
        )
    }

    private fun searchResponse(offset: Int, limit: Int): ModrinthSearchResponse =
        ModrinthSearchResponse(
            hits = listOf(sampleHit()),
            offset = offset,
            limit = limit,
            total_hits = 1
        )

    private fun sampleHit(): ModrinthSearchHit =
        ModrinthSearchHit(
            project_id = "project-id",
            project_type = "mod",
            slug = "project-slug",
            author = "Author",
            title = "Project Title",
            description = "Description",
            categories = listOf("magic"),
            display_categories = listOf("Magic"),
            versions = listOf("1.20.1"),
            downloads = 1337,
            follows = 42,
            icon_url = null,
            date_created = "2024-01-01T00:00:00Z",
            date_modified = "2024-01-02T00:00:00Z",
            latest_version = "1.0.0",
            license = "MIT",
            client_side = "optional",
            server_side = "required",
            gallery = emptyList(),
            featured_gallery = null,
            color = null
        )
}

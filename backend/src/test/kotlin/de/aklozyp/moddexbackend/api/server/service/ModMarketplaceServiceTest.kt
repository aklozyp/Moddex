package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.api.modrinth.ModrinthService
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.dto.ModrinthSearchResponse
import de.aklozyp.moddexbackend.model.enums.ModDataProvider
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import kotlin.test.assertEquals

class ModMarketplaceServiceTest {

    private lateinit var modrinthService: ModrinthService
    private lateinit var serverSettingsService: ServerSettingsService
    private lateinit var modMarketplaceService: ModMarketplaceService

    @BeforeEach
    fun setUp() {
        modrinthService = mockk()
        serverSettingsService = mockk()
        modMarketplaceService = ModMarketplaceService(serverSettingsService, modrinthService)
    }

    @Test
    fun `searchMods should call modrinthService when provider is MODRINTH`() {
        // Given
        val settings = ServerSettings().apply { modProvider = ModDataProvider.MODRINTH }
        val expectedResponse = ModrinthSearchResponse(emptyList(), 0, 0, 0)
        every { serverSettingsService.getServerSettings() } returns settings
        every { modrinthService.searchMods(any(), any(), any(), any(), any(), any(), any()) } returns expectedResponse

        // When
        val result = modMarketplaceService.searchMods("query", "loader", "1.16.5", emptyList(), 10, 0, "relevance")

        // Then
        assertEquals(expectedResponse, result)
        verify { modrinthService.searchMods("query", "loader", "1.16.5", emptyList(), 10, 0, "relevance") }
    }

    @Test
    fun `searchMods should throw NotImplementedError when provider is CURSEFORGE`() {
        // Given
        val settings = ServerSettings().apply { modProvider = ModDataProvider.CURSEFORGE }
        every { serverSettingsService.getServerSettings() } returns settings

        // When & Then
        assertThrows<NotImplementedError> {
            modMarketplaceService.searchMods("query", "loader", "1.16.5", emptyList(), 10, 0, "relevance")
        }
    }

    @Test
    fun `recommendedMods should call modrinthService when provider is MODRINTH`() {
        // Given
        val settings = ServerSettings().apply { modProvider = ModDataProvider.MODRINTH }
        val expectedResponse = ModrinthSearchResponse(emptyList(), 0, 0, 0)
        every { serverSettingsService.getServerSettings() } returns settings
        every { modrinthService.searchMods(any(), any(), any(), any(), any(), any(), any()) } returns expectedResponse

        // When
        val result = modMarketplaceService.recommendedMods("loader", "1.16.5", emptyList(), 10, 0, "downloads")

        // Then
        assertEquals(expectedResponse, result)
        verify { modrinthService.searchMods(null, "loader", "1.16.5", emptyList(), 10, 0, "downloads") }
    }

    @Test
    fun `getProjectDetails should throw NotImplementedError when provider is CURSEFORGE`() {
        // Given
        val settings = ServerSettings().apply { modProvider = ModDataProvider.CURSEFORGE }
        every { serverSettingsService.getServerSettings() } returns settings

        // When & Then
        assertThrows<NotImplementedError> {
            modMarketplaceService.getProjectDetails("projectId", "loader", "1.16.5")
        }
    }
}
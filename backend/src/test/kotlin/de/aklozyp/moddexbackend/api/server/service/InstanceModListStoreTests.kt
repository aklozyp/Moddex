package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.registerKotlinModule
import de.aklozyp.moddexbackend.services.Logger
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import java.nio.file.Files
import java.nio.file.Path
import java.util.Comparator
import java.util.UUID

class InstanceModListStoreTests {

    private val objectMapper = ObjectMapper().registerKotlinModule()
    private val logger: Logger = mock(Logger::class.java)
    private val store = InstanceModListStore(objectMapper, logger)
    private lateinit var tempDir: Path

    @BeforeEach
    fun setup() {
        tempDir = Files.createTempDirectory("modlist-store-test")
    }

    @AfterEach
    fun cleanup() {
        if (Files.exists(tempDir)) {
            Files.walk(tempDir)
                .sorted(Comparator.reverseOrder())
                .forEach { Files.deleteIfExists(it) }
        }
    }

    @Test
    fun `ensure creates modlist with instance id`() {
        val instanceId = UUID.randomUUID()

        val modList = store.ensure(tempDir, instanceId)

        assertEquals(instanceId, modList.instanceId)
        val modListPath = store.modListPath(tempDir)
        assertTrue(Files.exists(modListPath))

        val loaded = store.load(tempDir, instanceId)
        assertEquals(instanceId, loaded.instanceId)
        assertTrue(loaded.mods.isEmpty())
    }

    @Test
    fun `load returns empty list if file is missing`() {
        val instanceId = UUID.randomUUID()
        val loaded = store.load(tempDir, instanceId)
        assertEquals(instanceId, loaded.instanceId)
        assertTrue(loaded.mods.isEmpty())
    }
}

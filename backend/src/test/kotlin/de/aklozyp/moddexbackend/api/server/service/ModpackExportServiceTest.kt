package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.model.mods.InstanceModList
import de.aklozyp.moddexbackend.model.mods.InstalledMod
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.clearMocks
import io.mockk.every
import io.mockk.mockk
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.fail
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import java.util.Comparator
import java.util.zip.ZipInputStream

class ModpackExportServiceTest {

    private val objectMapper = jacksonObjectMapper()
    private val instanceService = mockk<InstanceService>()
    private val modListStore = mockk<InstanceModListStore>()
    private val logger = mockk<Logger>(relaxed = true)

    private lateinit var tempDir: Path
    private lateinit var service: ModpackExportService

    @BeforeEach
    fun setUp() {
        clearMocks(instanceService, modListStore)
        service = ModpackExportService(objectMapper, instanceService, modListStore, logger)
        tempDir = Files.createTempDirectory("modpack-export-test-")
    }

    @AfterEach
    fun tearDown() {
        if (::tempDir.isInitialized) {
            Files.walk(tempDir).use { stream ->
                stream.sorted(Comparator.reverseOrder())
                    .forEach { Files.deleteIfExists(it) }
            }
        }
    }

    @Test
    fun `export adds fileSize to modrinth index`() {
        val instanceId = UUID.randomUUID()
        val instance = Instance(
            id = instanceId,
            name = "Test Pack",
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "47.4.9",
        )

        val modsDir = tempDir.resolve("mods")
        Files.createDirectories(modsDir)
        val fileName = "test-mod-1.0.0.jar"
        val fileBytes = ByteArray(16) { it.toByte() }
        Files.write(modsDir.resolve(fileName), fileBytes)

        val mod = InstalledMod(
            projectId = "testProject",
            projectSlug = "test-mod",
            versionId = "version123",
            versionNumber = "1.0.0",
            fileName = fileName,
            displayName = "Test Mod",
            downloadUrl = "https://example.com/mod.jar",
            sha1 = "0123456789abcdef0123456789abcdef01234567",
            sha512 = "a".repeat(128),
            size = null,
            installedAt = "2024-01-01T00:00:00Z",
        )

        val modList = InstanceModList(instanceId = instanceId, mods = mutableListOf(mod))

        every { instanceService.getInstanceById(instanceId) } returns instance
        every { instanceService.getInstancePath(instanceId) } returns tempDir
        every { modListStore.load(tempDir, instanceId) } returns modList

        val archive = service.export(instanceId, ModpackFormat.MODRINTH)

        ZipInputStream(ByteArrayInputStream(archive.bytes)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (entry.name == "modrinth.index.json") {
                    val content = zip.readAllBytes().toString(StandardCharsets.UTF_8)
                    val root = objectMapper.readTree(content)
                    val fileNode = root["files"].first()
                    assertEquals(fileBytes.size.toLong(), fileNode["fileSize"].asLong())
                    assertEquals("mods/$fileName", fileNode["path"].asText())
                    return
                }
            }
        }

        fail<Unit>("modrinth.index.json entry not found in exported archive")
    }
}

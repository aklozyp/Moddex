package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.mockk
import io.mockk.verify
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import org.springframework.web.server.ResponseStatusException
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID

class InstanceStartManifestStoreTest {

    @TempDir
    lateinit var tempDir: Path

    private val logger = mockk<Logger>(relaxed = true)
    private val store = InstanceStartManifestStore(jacksonObjectMapper(), logger)
    private val objectMapper = jacksonObjectMapper()

    @Test
    fun `record stores the resolved argument file contract with a relative path`() {
        val directory = installForgeLayout("1.20.1-47.2.0", "1.20.1-47.10.0")

        store.record(forgeInstance(), directory)

        val manifest = readManifest(directory)
        assertEquals(ModLoader.FORGE, manifest.loader)
        assertEquals(
            "libraries/net/minecraftforge/forge/1.20.1-47.10.0/${preferredArgsFile()}",
            manifest.argsFile,
            "the declared loader version must win over the leftover older build",
        )
        assertNull(manifest.jarPath, "an argument-file contract has no startable jar")
        assertThat(manifest.createdAt).isNotBlank()
        assertFalse(manifest.argsFile!!.startsWith("/"), "the manifest must not store absolute paths")
    }

    @Test
    fun `record stores the resolved server jar contract for vanilla`() {
        val directory = tempDir.resolve("vanilla")
        Files.createDirectories(directory)
        Files.createFile(directory.resolve("server.jar"))

        // A null loader is recorded as the VANILLA loader the start path uses.
        store.record(Instance(id = UUID.randomUUID(), gameVersion = "1.20.1"), directory)

        val manifest = readManifest(directory)
        assertEquals(ModLoader.VANILLA, manifest.loader)
        assertNull(manifest.argsFile)
        assertEquals("server.jar", manifest.jarPath)
    }

    @Test
    fun `record stores no manifest and keeps the installation outcome when nothing is resolvable`() {
        // An installer run that produced no known start entry (mirrored by the
        // fake runner in the installer tests) must not fail the installation.
        val directory = tempDir.resolve("empty")
        Files.createDirectories(directory)

        store.record(forgeInstance(), directory)

        assertFalse(Files.exists(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME)))
        verify { logger.warn(withArg { it.contains("No startable entry") && it.contains("legacy discovery") }) }
    }

    @Test
    fun `record overwrites a corrupt manifest so a reinstall repairs it`() {
        val directory = installForgeLayout("1.20.1-47.2.0")
        Files.writeString(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME), "{ broken")

        store.record(forgeInstance(), directory)

        val manifest = readManifest(directory)
        assertEquals(ModLoader.FORGE, manifest.loader)
        assertEquals("libraries/net/minecraftforge/forge/1.20.1-47.2.0/${preferredArgsFile()}", manifest.argsFile)
    }

    @Test
    fun `record refuses to replace a symbolic-link manifest`() {
        val directory = installForgeLayout("1.20.1-47.2.0")
        val outside = Files.createTempFile("start-manifest-outside", ".json")
        Files.writeString(outside, "do not overwrite me")
        val link = runCatching {
            Files.createSymbolicLink(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME), outside)
        }
        assumeTrue(link.isSuccess, "This filesystem does not support creating symbolic links")
        val manifestFile = directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME)
        try {
            val error = assertThrows<ResponseStatusException> { store.record(forgeInstance(), directory) }

            assertTrue(error.reason!!.contains("symbolic link"))
            assertTrue(error.reason!!.contains("then start the installation again"))
            assertTrue(Files.isSymbolicLink(manifestFile), "the planted link must remain untouched")
            assertEquals("do not overwrite me", Files.readString(outside))
        } finally {
            Files.deleteIfExists(manifestFile)
            Files.deleteIfExists(outside)
        }
    }

    @Test
    fun `record keeps the installation outcome when the manifest cannot be written`() {
        val directory = installForgeLayout("1.20.1-47.2.0")
        // The write denial is simulated structurally instead of with directory
        // permissions: a directory occupies the manifest path, so the atomic
        // replacement fails for every account (an effective root user would
        // bypass permission checks). The instance directory itself stays
        // writable, so the pending file and its cleanup still work as in a
        // real degraded write.
        Files.createDirectories(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME))
        try {
            // A missing manifest degrades the start to the documented legacy
            // discovery, so the installation itself must not be failed here.
            store.record(forgeInstance(), directory)

            assertFalse(
                Files.isRegularFile(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME)),
                "no start manifest file may be stored when the write fails",
            )
            assertTrue(
                Files.isDirectory(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME)),
                "the blocking structure must remain untouched",
            )
            verify { logger.error(withArg { it.contains("Could not store the start manifest") }) }
        } finally {
            Files.deleteIfExists(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME))
        }
    }

    @Test
    fun `resolveForStart returns null for an instance without a stored manifest`() {
        assertNull(store.resolveForStart(forgeInstance(), tempDir))
    }

    @Test
    fun `resolveForStart resolves a stored argument file entry`() {
        val directory = installForgeLayout("1.20.1-47.2.0")
        store.record(forgeInstance(), directory)

        val entry = store.resolveForStart(forgeInstance(), directory)

        assertEquals(
            StartEntry.ArgumentsFile("libraries/net/minecraftforge/forge/1.20.1-47.2.0/${preferredArgsFile()}"),
            entry,
        )
    }

    @Test
    fun `resolveForStart resolves a stored server jar entry`() {
        val directory = tempDir.resolve("vanilla")
        Files.createDirectories(directory)
        Files.createFile(directory.resolve("server.jar"))
        store.record(Instance(id = UUID.randomUUID(), modLoader = ModLoader.VANILLA), directory)

        val entry = store.resolveForStart(Instance(id = UUID.randomUUID(), modLoader = ModLoader.VANILLA), directory)

        assertEquals(StartEntry.ServerJar("server.jar"), entry)
    }

    @Test
    fun `resolveForStart ignores unknown manifest fields for format compatibility`() {
        val directory = tempDir.resolve("vanilla")
        Files.createDirectories(directory)
        Files.createFile(directory.resolve("server.jar"))
        Files.writeString(
            directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME),
            """{"loader":"VANILLA","jarPath":"server.jar","futureField":"ignored"}""",
        )

        val entry = store.resolveForStart(Instance(id = UUID.randomUUID(), modLoader = ModLoader.VANILLA), directory)

        assertEquals(StartEntry.ServerJar("server.jar"), entry)
    }

    @Test
    fun `resolveForStart rejects an unreadable manifest with guidance instead of guessing`() {
        val directory = tempDir.resolve("vanilla")
        Files.createDirectories(directory)
        Files.createFile(directory.resolve("server.jar"))
        Files.writeString(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME), "{ broken")

        val error = assertThrows<IllegalStateException> {
            store.resolveForStart(Instance(id = UUID.randomUUID(), modLoader = ModLoader.VANILLA), directory)
        }

        assertTrue(error.message!!.contains("could not be read"))
        assertTrue(error.message!!.contains("reinstall"))
        // A corrupt manifest must never silently fall back to the jar search.
        assertThat(error.message).doesNotContain("server.jar found")
    }

    @Test
    fun `resolveForStart rejects a manifest whose loader no longer matches the instance`() {
        val directory = tempDir.resolve("vanilla")
        Files.createDirectories(directory)
        Files.createFile(directory.resolve("server.jar"))
        Files.writeString(
            directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME),
            """{"loader":"FORGE","jarPath":"server.jar"}""",
        )

        val error = assertThrows<IllegalStateException> {
            store.resolveForStart(Instance(id = UUID.randomUUID(), modLoader = ModLoader.NEOFORGE), directory)
        }

        assertTrue(error.message!!.contains("created for loader FORGE"))
        assertTrue(error.message!!.contains("now declares NEOFORGE"))
        assertTrue(error.message!!.contains("Reinstall the instance"))
    }

    @Test
    fun `resolveForStart rejects a manifest without exactly one start entry`() {
        val directory = tempDir.resolve("vanilla")
        Files.createDirectories(directory)
        for (manifest in listOf("""{"loader":"VANILLA"}""", """{"loader":"VANILLA","argsFile":"a","jarPath":"b"}""")) {
            val manifestFile = directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME)
            Files.writeString(manifestFile, manifest)

            val error = assertThrows<IllegalStateException> {
                store.resolveForStart(Instance(id = UUID.randomUUID(), modLoader = ModLoader.VANILLA), directory)
            }

            assertTrue(error.message!!.contains("exactly one start entry"))
            assertTrue(error.message!!.contains("Reinstall the instance"))
            Files.delete(manifestFile)
        }
    }

    @ParameterizedTest
    @ValueSource(strings = ["../outside.jar", "/etc/moddex/evil.jar", "libraries\\net\\x\\unix_args.txt", ".", ""])
    fun `resolveForStart rejects manifest paths that leave the instance directory`(path: String) {
        val directory = tempDir.resolve("vanilla")
        Files.createDirectories(directory)
        Files.createFile(directory.resolve("server.jar"))
        Files.writeString(
            directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME),
            """{"loader":"VANILLA","jarPath":"${path.replace("\\", "\\\\")}"}""",
        )

        val error = assertThrows<IllegalStateException> {
            store.resolveForStart(Instance(id = UUID.randomUUID(), modLoader = ModLoader.VANILLA), directory)
        }

        assertThat(error.message).contains("invalid server jar path")
        assertThat(error.message).contains("Reinstall the instance")
    }

    @Test
    fun `resolveForStart rejects a manifest entry that is missing on disk`() {
        val directory = tempDir.resolve("vanilla")
        Files.createDirectories(directory)
        // The heuristic jar search would still find server.jar; the manifest
        // contract must be rejected instead of guessed around.
        Files.createFile(directory.resolve("server.jar"))
        Files.writeString(
            directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME),
            """{"loader":"VANILLA","jarPath":"missing-server.jar"}""",
        )

        val error = assertThrows<IllegalStateException> {
            store.resolveForStart(Instance(id = UUID.randomUUID(), modLoader = ModLoader.VANILLA), directory)
        }

        assertTrue(error.message!!.contains("missing-server.jar"))
        assertTrue(error.message!!.contains("Restore it from a backup or reinstall"))
    }

    private fun forgeInstance() = Instance(
        id = UUID.randomUUID(),
        name = "forge-instance",
        modLoader = ModLoader.FORGE,
        gameVersion = "1.20.1",
        modLoaderVersion = "47.10.0",
    )

    /** Mirrors the Maven layout a modern Forge `--installServer` run leaves behind. */
    private fun installForgeLayout(vararg versions: String): Path {
        val directory = tempDir.resolve("forge")
        for (version in versions) {
            val versionDir = directory.resolve("libraries")
                .resolve("net/minecraftforge/forge")
                .resolve(version)
            Files.createDirectories(versionDir)
            Files.createFile(versionDir.resolve("unix_args.txt"))
            Files.createFile(versionDir.resolve("win_args.txt"))
        }
        return directory
    }

    private fun readManifest(directory: Path): InstanceStartManifest =
        objectMapper.readValue(
            directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME).toFile(),
        )

    private fun preferredArgsFile() = ProcessManagerService.preferredArgsFileName(System.getProperty("os.name"))
}

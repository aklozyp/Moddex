package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.model.mods.InstanceModList
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.verify
import io.mockk.verifyOrder
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import org.springframework.web.server.ResponseStatusException
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.nio.file.AccessDeniedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.stream.Stream

class InstanceDeletionServiceTest {

    @TempDir
    lateinit var tempDir: Path

    private val logger = mockk<Logger>(relaxed = true)
    private val launcher = mockk<ServerProcessLauncher>()
    private val process = RecordingProcess()
    private lateinit var directories: ModdexDirectories
    private lateinit var instanceService: InstanceService
    private lateinit var processManagerService: ProcessManagerService
    private lateinit var deletionService: InstanceDeletionService

    @BeforeEach
    fun setUp() {
        directories = object : ModdexDirectories {
            override val configDir: Path = tempDir.resolve("config")
            override val dataDir: Path = tempDir.resolve("data")
            override val logsDir: Path = tempDir.resolve("logs")
        }
        val serverSettingsService = mockk<ServerSettingsService>()
        every { serverSettingsService.getServerSettings() } returns ServerSettings().apply {
            projectPath = directories.dataDir.toString()
        }
        val instanceInstallerService = mockk<InstanceInstallerService>()
        every { instanceInstallerService.downloadInstaller(any(), any()) } just runs
        val modListStore = mockk<InstanceModListStore>()
        every { modListStore.ensure(any(), any()) } answers { InstanceModList(instanceId = secondArg()) }

        instanceService = InstanceService(
            serverSettingsService,
            jacksonObjectMapper(),
            instanceInstallerService,
            modListStore,
            logger,
            directories,
        )
        val eulaService = mockk<EulaService>()
        every { eulaService.isEulaAccepted(any()) } returns true
        processManagerService = ProcessManagerService(
            instanceService,
            eulaService,
            logger,
            launcher,
            2_000,
            InstanceStartManifestStore(jacksonObjectMapper(), logger),
        )
        every { launcher.start(any(), any()) } returns process
        deletionService = InstanceDeletionService(instanceService, processManagerService, logger)
    }

    // -- Orchestration contract -------------------------------------------------

    @Test
    fun `deletion is blocked without touching the instance when the process gate refuses`() {
        val id = UUID.randomUUID()
        val instanceService = mockk<InstanceService>()
        val processManagerService = mockk<ProcessManagerService>(relaxed = true)
        val service = InstanceDeletionService(instanceService, processManagerService, logger)
        every { processManagerService.beginDeletion(id) } returns false

        val exception = assertThrows<InstanceStillRunningException> { service.deleteInstanceById(id) }

        assertTrue(exception.message!!.contains("Stop the instance in the console"))
        assertTrue(exception.message!!.contains("then retry the deletion"))
        assertTrue(exception.message!!.contains("No instance data was changed"))
        verify(exactly = 0) { instanceService.deleteInstanceById(any()) }
        verify(exactly = 0) { processManagerService.endDeletion(any()) }
    }

    @Test
    fun `deletion runs under the reservation and releases it afterwards`() {
        val id = UUID.randomUUID()
        val instanceService = mockk<InstanceService>()
        val processManagerService = mockk<ProcessManagerService>(relaxed = true)
        val service = InstanceDeletionService(instanceService, processManagerService, logger)
        every { processManagerService.beginDeletion(id) } returns true
        every { instanceService.deleteInstanceById(id) } returns Unit

        service.deleteInstanceById(id)

        verifyOrder {
            processManagerService.beginDeletion(id)
            instanceService.deleteInstanceById(id)
            processManagerService.endDeletion(id)
        }
    }

    @Test
    fun `a failed instance deletion releases the reservation and propagates the guided error`() {
        val id = UUID.randomUUID()
        val instanceService = mockk<InstanceService>()
        val processManagerService = mockk<ProcessManagerService>(relaxed = true)
        val service = InstanceDeletionService(instanceService, processManagerService, logger)
        every { processManagerService.beginDeletion(id) } returns true
        every { instanceService.deleteInstanceById(id) } throws
            InstanceDeletionException(listOf("worlds/level.dat", "worlds"), "Locked")

        val exception = assertThrows<InstanceDeletionException> { service.deleteInstanceById(id) }

        assertThat(exception.remainingPaths).contains("worlds/level.dat")
        verify(exactly = 1) { processManagerService.endDeletion(id) }
    }

    // -- End to end against the real instance and process services --------------

    @Test
    fun `a running instance blocks deletion and keeps all data until it is stopped`() {
        val id = createInstance("Running")
        val instanceDir = directories.dataDir.resolve("instances").resolve("Running")
        val worldFile = instanceDir.resolve("world").resolve("level.dat")
        Files.createDirectories(worldFile.parent)
        Files.write(worldFile, byteArrayOf(1, 2, 3))
        Files.createFile(instanceDir.resolve("server.jar"))
        processManagerService.startInstance(id)

        val exception = assertThrows<InstanceStillRunningException> { deletionService.deleteInstanceById(id) }

        // Guided error message; the deletion never stopped or killed the server
        // itself: the orderly stop stays an explicit user action.
        assertTrue(exception.message!!.contains("Stop the instance in the console"))
        assertEquals("", process.written.toString())
        assertEquals(0, process.forceKills.get())
        assertTrue(process.alive.get())
        // The running server's world data and configuration are untouched.
        assertTrue(Files.exists(worldFile))
        assertTrue(Files.exists(instanceDir.resolve("instance.json")))
        assertEquals("Running", instanceService.getInstanceById(id).name)

        processManagerService.shutdown()
        assertFalse(process.alive.get())
        assertEquals("stop\n", process.written.toString())
    }

    @Test
    fun `a stopped instance is deleted and cannot be restarted into the removed directory`() {
        val id = createInstance("Stopped")
        val instanceDir = directories.dataDir.resolve("instances").resolve("Stopped")
        val worldDir = instanceDir.resolve("world")
        Files.createDirectories(worldDir)
        Files.createFile(instanceDir.resolve("server.jar"))
        processManagerService.startInstance(id)
        process.alive.set(false)

        deletionService.deleteInstanceById(id)

        assertFalse(Files.exists(instanceDir))
        assertFalse(Files.exists(worldDir))
        // With the directory gone no game server can be started for this id
        // again, so nothing can write into the removed world paths.
        val startError = assertThrows<ResponseStatusException> { processManagerService.startInstance(id) }
        assertThat(startError.statusCode.value()).isEqualTo(404)
        // Only the initial start ever reached the launcher.
        verify(exactly = 1) { launcher.start(any(), any()) }
    }

    @Test
    fun `while a deletion reservation is held no game server can start into the doomed directory`() {
        val id = createInstance("Doomed")
        Files.createFile(directories.dataDir.resolve("instances").resolve("Doomed").resolve("server.jar"))

        assertTrue(processManagerService.beginDeletion(id))
        val rejection = assertThrows<IllegalStateException> { processManagerService.startInstance(id) }
        assertTrue(rejection.message!!.contains("being deleted"))
        verify(exactly = 0) { launcher.start(any(), any()) }

        // Releasing the reservation restores the normal start behavior; the
        // deletion itself decides whether to proceed with the removal.
        processManagerService.endDeletion(id)
        processManagerService.startInstance(id)
        processManagerService.shutdown()
        assertFalse(process.alive.get())
    }

    @Test
    fun `a failed deletion keeps the world data and restores a clean reservation state`() {
        assumePosixDenialIsEnforced()
        val id = createInstance("Locked")
        val instanceDir = directories.dataDir.resolve("instances").resolve("Locked")
        val worlds = instanceDir.resolve("worlds")
        Files.createDirectories(worlds)
        Files.write(worlds.resolve("level.dat"), byteArrayOf(1))
        Files.setPosixFilePermissions(worlds, PosixFilePermissions.fromString("r-xr-xr-x"))
        try {
            val exception = assertThrows<InstanceDeletionException> { deletionService.deleteInstanceById(id) }

            assertThat(exception.remainingPaths).contains("worlds/level.dat")
            assertTrue(Files.exists(worlds.resolve("level.dat")))
            // The released reservation shows no leftover gate state; a retry
            // (after the user resolved the file problem) can take it again.
            assertTrue(processManagerService.beginDeletion(id))
            processManagerService.endDeletion(id)
        } finally {
            Files.setPosixFilePermissions(worlds, PosixFilePermissions.fromString("rwxr-xr-x"))
        }
    }

    private fun createInstance(name: String): UUID =
        instanceService.createAndInstallInstance(
            Instance(name = name, gameVersion = "1.20.4", modLoader = ModLoader.VANILLA),
        ).id!!

    /**
     * Probes that removing a file from a write-protected directory actually
     * fails; skips the caller when the environment (e.g. root) bypasses the
     * denial, because the error path could not be exercised there.
     */
    private fun assumePosixDenialIsEnforced() {
        val probe = Files.createTempDirectory("posix-denial-probe")
        val child = probe.resolve("child.txt")
        Files.createFile(child)
        org.junit.jupiter.api.Assumptions.assumeTrue(
            Files.getFileStore(probe).supportsFileAttributeView("posix"),
            "Filesystem has no POSIX attribute view; the permission error path cannot be exercised here",
        )
        Files.setPosixFilePermissions(probe, PosixFilePermissions.fromString("r-xr-xr-x"))
        try {
            Files.delete(child)
            org.junit.jupiter.api.Assumptions.assumeTrue(
                false,
                "Filesystem does not enforce directory permission denial (running as root?)",
            )
        } catch (_: AccessDeniedException) {
            // Enforced as expected; the POSIX error path can be exercised.
        } finally {
            Files.setPosixFilePermissions(probe, PosixFilePermissions.fromString("rwxr-xr-x"))
            Files.deleteIfExists(child)
            Files.deleteIfExists(probe)
        }
    }

    /** Minimal in-memory game-server stand-in; no real process is ever started. */
    private class RecordingProcess : Process() {
        val alive = AtomicBoolean(true)
        val forceKills = AtomicInteger()
        val written = ByteArrayOutputStream()

        override fun getOutputStream(): OutputStream = written
        override fun getInputStream() = ByteArrayInputStream(byteArrayOf())
        override fun getErrorStream() = ByteArrayInputStream(byteArrayOf())
        override fun isAlive() = alive.get()
        override fun pid() = 5678L
        override fun descendants(): Stream<ProcessHandle> = Stream.empty()
        override fun waitFor(): Int = error("Unbounded wait must not be used")
        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            alive.set(false)
            return true
        }

        override fun exitValue(): Int {
            check(!alive.get()) { "Process is still alive" }
            return 0
        }

        override fun destroy() {
            alive.set(false)
        }

        override fun destroyForcibly(): Process {
            forceKills.incrementAndGet()
            alive.set(false)
            return this
        }
    }
}

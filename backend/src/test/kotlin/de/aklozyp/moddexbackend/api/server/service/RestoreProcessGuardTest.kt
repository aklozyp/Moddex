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
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SecureDirectoryStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.stream.Stream
import kotlin.concurrent.thread
import org.junit.jupiter.api.Assumptions.assumeTrue

/**
 * End-to-end tests of the restore process guard (#275): the real backup
 * service meets the real process manager, so the guard decision, the start
 * gate and the deletion gate are proven against each other. No real game
 * server is ever started; a minimal in-memory process stand-in records every
 * command so the tests prove the guard never stops the instance itself.
 */
class RestoreProcessGuardTest {

    @TempDir
    lateinit var tempDir: Path

    private val logger = mockk<Logger>(relaxed = true)
    private val launcher = mockk<ServerProcessLauncher>()
    private val process = RecordingProcess()
    private lateinit var directories: ModdexDirectories
    private lateinit var instanceService: InstanceService
    private lateinit var processManagerService: ProcessManagerService
    private lateinit var backupService: BackupService
    private lateinit var deletionService: InstanceDeletionService

    @BeforeEach
    fun setUp() {
        assumeSecureDirectoryStreamSupported()
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
        backupService = BackupService(
            instanceService,
            processManagerService,
            InstanceBackupOperationLocks(),
            logger,
            jacksonObjectMapper(),
            1_000,
        )
        deletionService = InstanceDeletionService(instanceService, processManagerService, logger)
    }

    @Test
    fun `a running instance blocks the restore and no command reaches the game server`() {
        val id = createInstance("Running")
        val instanceDir = directories.dataDir.resolve("instances").resolve("Running")
        val worldFile = instanceDir.resolve("world").resolve("level.dat")
        Files.createDirectories(worldFile.parent)
        Files.write(worldFile, "world data v1".toByteArray())
        Files.createFile(instanceDir.resolve("server.jar"))
        val backup = backupService.createBackup(id)
        // State after the backup: the live server has meanwhile corrupted the
        // world data that a restore would rebuild.
        Files.write(worldFile, "world data v2 (corrupted)".toByteArray())
        processManagerService.startInstance(id)

        val exception = assertThrows<ResponseStatusException> {
            backupService.restoreBackup(id, backup.name)
        }

        // Guided conflict error; the restore never stopped or killed the
        // server itself: the orderly stop stays an explicit user action.
        assertThat(exception.statusCode.value()).isEqualTo(409)
        assertThat(exception.reason)
            .contains("Stop the instance in the console")
            .contains("STOPPED")
            .contains("retry the restore")
            .contains("No instance data was changed")
            .doesNotContain(instanceDir.toString())
        assertEquals("", process.written.toString())
        assertEquals(0, process.forceKills.get())
        assertTrue(process.alive.get())
        // The running server's world data is untouched by the blocked restore.
        assertThat(Files.readAllBytes(worldFile)).isEqualTo("world data v2 (corrupted)".toByteArray())
        assertTrue(Files.exists(instanceDir.resolve("backups").resolve(backup.name)))
        assertNoRestoreWorkingEntries(instanceDir)

        processManagerService.shutdown()
        assertFalse(process.alive.get())
        // The only stop the server ever received came from the backend
        // shutdown itself, never from the blocked restore.
        assertEquals("stop\n", process.written.toString())
    }

    @Test
    fun `while a restore is in progress no game server can start into the replaced world data`() {
        val id = createInstance("Restoring")
        val instanceDir = directories.dataDir.resolve("instances").resolve("Restoring")
        val worldFile = instanceDir.resolve("world").resolve("level.dat")
        Files.createDirectories(worldFile.parent)
        Files.write(worldFile, "world data v1".toByteArray())
        Files.createFile(instanceDir.resolve("server.jar"))
        val backup = backupService.createBackup(id)
        Files.write(worldFile, "world data v2 (corrupted)".toByteArray())

        holdRestoreInsideAdoption()
        val restoreThread = startRestoreInBackground(id, backup.name)
        try {
            assertThat(insideRestore.await(10, TimeUnit.SECONDS)).isTrue()

            val rejection = assertThrows<IllegalStateException> { processManagerService.startInstance(id) }
            assertTrue(rejection.message!!.contains("being restored"))
            // The rejected start never reached the launcher, so no game server
            // can write into the world data the restore is replacing.
            verify(exactly = 0) { launcher.start(any(), any()) }
        } finally {
            releaseRestore.countDown()
        }
        restoreThread.join(TimeUnit.SECONDS.toMillis(10))
        assertFalse(restoreThread.isAlive)

        // The restore completed fully; only afterwards does the gate allow
        // the start again.
        assertThat(Files.readAllBytes(worldFile)).isEqualTo("world data v1".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)
        processManagerService.startInstance(id)
        verify(exactly = 1) { launcher.start(any(), any()) }
        assertEquals("", process.written.toString())

        processManagerService.shutdown()
    }

    @Test
    fun `while a restore is in progress the instance cannot be deleted`() {
        val id = createInstance("Restoring-Delete")
        val instanceDir = directories.dataDir.resolve("instances").resolve("Restoring-Delete")
        val worldFile = instanceDir.resolve("world").resolve("level.dat")
        Files.createDirectories(worldFile.parent)
        Files.write(worldFile, "world data v1".toByteArray())
        Files.createFile(instanceDir.resolve("server.jar"))
        val backup = backupService.createBackup(id)

        holdRestoreInsideAdoption()
        val restoreThread = startRestoreInBackground(id, backup.name)
        try {
            assertThat(insideRestore.await(10, TimeUnit.SECONDS)).isTrue()

            val exception = assertThrows<InstanceStillRunningException> {
                deletionService.deleteInstanceById(id)
            }
            assertTrue(exception.message!!.contains("No instance data was changed"))
            // The deletion gate refused the reservation, so the deletion never
            // removed anything while the restore was replacing the data.
            assertTrue(Files.exists(instanceDir))
        } finally {
            releaseRestore.countDown()
        }
        restoreThread.join(TimeUnit.SECONDS.toMillis(10))
        assertFalse(restoreThread.isAlive)
        assertThat(Files.readAllBytes(worldFile)).isEqualTo("world data v1".toByteArray())

        // With the reservation released, the deletion is permitted again.
        deletionService.deleteInstanceById(id)
        assertFalse(Files.exists(instanceDir))
    }

    @Test
    fun `a failed restore frees the reservation so the instance can start again`() {
        val id = createInstance("Failed-Restore")
        val instanceDir = directories.dataDir.resolve("instances").resolve("Failed-Restore")
        val worldFile = instanceDir.resolve("world").resolve("level.dat")
        Files.createDirectories(worldFile.parent)
        Files.write(worldFile, "world data v1".toByteArray())
        Files.createFile(instanceDir.resolve("server.jar"))
        val backup = backupService.createBackup(id)
        Files.write(worldFile, "world data v2 (corrupted)".toByteArray())

        backupService.onBeforePublishRestoreEntry = { entryName ->
            if (entryName == "world") throw IOException("simulated adoption failure")
        }

        val exception = assertThrows<ResponseStatusException> {
            backupService.restoreBackup(id, backup.name)
        }

        assertThat(exception.statusCode.value()).isEqualTo(500)
        // The adoption rolled the previous data back.
        assertThat(Files.readAllBytes(worldFile)).isEqualTo("world data v2 (corrupted)".toByteArray())

        // The failed restore released its reservation: starting the instance
        // is possible again; whether to restart after the failed restore
        // stays the user's decision.
        processManagerService.startInstance(id)
        verify(exactly = 1) { launcher.start(any(), any()) }
        assertEquals("", process.written.toString())

        processManagerService.shutdown()
        assertFalse(process.alive.get())
    }

    @Test
    fun `a stopped instance restores fully and starts again afterwards`() {
        val id = createInstance("Stopped")
        val instanceDir = directories.dataDir.resolve("instances").resolve("Stopped")
        val worldDir = instanceDir.resolve("world")
        val worldFile = worldDir.resolve("level.dat")
        Files.createDirectories(worldFile.parent)
        Files.write(worldFile, "world data v1".toByteArray())
        Files.createFile(instanceDir.resolve("server.jar"))
        val backup = backupService.createBackup(id)
        Files.write(worldFile, "world data v2 (corrupted)".toByteArray())
        // Data that was added after the backup must not survive the restore.
        Files.createDirectories(worldDir.resolve("region"))
        Files.write(worldDir.resolve("region").resolve("r.0.0.mca"), "region".toByteArray())

        // The restore of a stopped instance is unaffected by the guard.
        backupService.restoreBackup(id, backup.name)

        assertThat(Files.readAllBytes(worldFile)).isEqualTo("world data v1".toByteArray())
        assertFalse(Files.exists(worldDir.resolve("region")))
        assertNoRestoreWorkingEntries(instanceDir)

        // After the fully successful restore the instance starts again; the
        // restarted server receives no command from the restore.
        processManagerService.startInstance(id)
        verify(exactly = 1) { launcher.start(any(), any()) }
        assertEquals("", process.written.toString())

        processManagerService.shutdown()
        assertFalse(process.alive.get())
    }

    private fun createInstance(name: String): UUID =
        instanceService.createAndInstallInstance(
            Instance(name = name, gameVersion = "1.20.4", modLoader = ModLoader.VANILLA),
        ).id!!

    private val insideRestore = CountDownLatch(1)
    private val releaseRestore = CountDownLatch(1)

    /**
     * Lets the next restore adopt exactly one entry and then hold it there,
     * so the tests can probe the start and deletion gates while the restore
     * reservation is genuinely held mid-operation.
     */
    private fun holdRestoreInsideAdoption() {
        val firstEntry = AtomicBoolean(true)
        backupService.onBeforePublishRestoreEntry = { _ ->
            if (firstEntry.getAndSet(false)) {
                insideRestore.countDown()
                releaseRestore.await(10, TimeUnit.SECONDS)
            }
        }
    }

    private fun startRestoreInBackground(id: UUID, backupName: String) = thread(start = true) {
        runCatching { backupService.restoreBackup(id, backupName) }
    }

    private fun assumeSecureDirectoryStreamSupported() {
        val supported = Files.newDirectoryStream(tempDir).use { it is SecureDirectoryStream<*> }
        assumeTrue(
            supported,
            "SecureDirectoryStream is not supported on this platform; backup creation fails there by design"
        )
    }

    private fun assertNoRestoreWorkingEntries(instanceDir: Path) {
        Files.list(instanceDir).use { entries ->
            val workingEntries = entries.map { it.fileName.toString() }.toList()
                .filter { it.startsWith(".restore-staging-") || it.startsWith(".restore-aside-") }
            assertThat(workingEntries).isEmpty()
        }
    }

    /** Minimal in-memory game-server stand-in; no real process is ever started. */
    private class RecordingProcess : Process() {
        val alive = AtomicBoolean(true)
        val forceKills = AtomicInteger()
        val written = ByteArrayOutputStream()

        override fun getOutputStream(): java.io.OutputStream = written
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

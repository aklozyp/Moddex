package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import de.aklozyp.moddexbackend.model.dto.BackupEntry
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import io.mockk.verifyOrder
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import org.springframework.http.HttpStatus
import org.springframework.web.server.ResponseStatusException
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SecureDirectoryStream
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import kotlin.concurrent.thread
import kotlin.io.path.name

class BackupServiceTest {

    @TempDir
    lateinit var tempDir: Path

    private val instanceService = mockk<InstanceService>()
    private val logger = mockk<Logger>(relaxed = true)
    private val processManagerService = mockk<ProcessManagerService>(relaxed = true) {
        // Default for every test that does not deal with a live world: the
        // instance is stopped, so the backup coordination stays inactive.
        every { isInstanceRunning(any()) } returns false
        // Default for every test that does not deal with the restore process
        // guard: the gate accepts the restore, so the restore itself is
        // exercised; the guard's own rejection path has dedicated tests.
        every { beginRestore(any()) } returns true
    }

    @Test
    fun `createBackup archives regular instance files`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val fileBytes = "instance data".toByteArray()
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), fileBytes)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir

        val backup = newBackupService().createBackup(instanceId)

        ZipFile(instanceDir.resolve("backups").resolve(backup.name).toFile()).use { zip ->
            val entry = zip.getEntry("level.dat")
            assertThat(entry).isNotNull
            assertThat(zip.getInputStream(entry).use { it.readAllBytes() }).containsExactly(*fileBytes)
        }
    }

    @Test
    fun `createBackup on a running instance flushes the world only after its confirmation and restores saving afterwards`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val fileBytes = "instance data".toByteArray()
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), fileBytes)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val consoleLines = CopyOnWriteArrayList<String>()
        val commandsSent = CopyOnWriteArrayList<String>()
        fakeRunningConsole(
            instanceId,
            // save-all flush stays unconfirmed here; the fake server thread
            // below appends the confirmation only once the test releases it.
            confirmableCommands = mapOf("save-off" to "Automatic saving is now disabled"),
            consoleLines = consoleLines,
            commandsSent = commandsSent
        )
        val flushEchoSent = CountDownLatch(1)
        val flushConfirmed = CountDownLatch(1)
        // The echo of the flush command is written synchronously with the
        // command like the real console reader does; the confirmation line is
        // appended by the fake server thread only after the test releases it.
        every { processManagerService.sendCommand(instanceId, "save-all flush") } answers {
            commandsSent.add("save-all flush")
            consoleLines.add("> save-all flush")
            flushEchoSent.countDown()
            Unit
        }
        thread(start = true, isDaemon = true) {
            flushEchoSent.await(10, TimeUnit.SECONDS)
            flushConfirmed.await(10, TimeUnit.SECONDS)
            consoleLines.add("Saved the game")
        }

        val published = CountDownLatch(1)
        val consoleAtPublish = AtomicReference<List<String>>()
        val commandsAtPublish = AtomicReference<List<String>>()
        val backupResult = AtomicReference<Result<BackupEntry>>()
        val backupService = newBackupService(worldSaveConfirmationTimeoutMillis = 5_000).apply {
            onReadyToPublish = { _ ->
                consoleAtPublish.set(consoleLines.toList())
                commandsAtPublish.set(commandsSent.toList())
                published.countDown()
            }
        }

        val runningBackup = thread(start = true) {
            backupResult.set(runCatching { backupService.createBackup(instanceId) })
        }

        assertThat(flushEchoSent.await(5, TimeUnit.SECONDS)).isTrue()
        // Without the flush confirmation the backup must not start writing or
        // publishing: no archive, no backups directory, no save-on yet.
        TimeUnit.MILLISECONDS.sleep(300)
        assertThat(published.getCount()).isEqualTo(1)
        assertThat(commandsSent).containsExactly("save-off", "save-all flush")
        assertThat(Files.exists(instanceDir.resolve("backups"))).isFalse()

        flushConfirmed.countDown()
        assertThat(published.await(5, TimeUnit.SECONDS)).isTrue()
        runningBackup.join(TimeUnit.SECONDS.toMillis(10))
        assertThat(runningBackup.isAlive).isFalse()

        val backup = backupResult.get().getOrThrow()
        assertThat(backup.name).endsWith(".zip")
        // The archive was written only after the confirmed save: at publish
        // time the console already contained the confirmed flush.
        val publishConsole = consoleAtPublish.get()
        val saveOffEcho = publishConsole.indexOf("> save-off")
        val saveOffConfirmation = publishConsole.indexOf("Automatic saving is now disabled")
        val flushEcho = publishConsole.indexOf("> save-all flush")
        val flushConfirmation = publishConsole.indexOf("Saved the game")
        assertThat(saveOffEcho).isLessThan(saveOffConfirmation)
        assertThat(saveOffConfirmation).isLessThan(flushEcho)
        assertThat(flushEcho).isLessThan(flushConfirmation)
        assertThat(commandsAtPublish.get()).containsExactly("save-off", "save-all flush")
        // save-on is restored after the archive was written.
        assertThat(commandsSent).containsExactly("save-off", "save-all flush", "save-on")
        ZipFile(instanceDir.resolve("backups").resolve(backup.name).toFile()).use { zip ->
            val entry = zip.getEntry("level.dat")
            assertThat(entry).isNotNull
            assertThat(zip.getInputStream(entry).use { it.readAllBytes() }).containsExactly(*fileBytes)
        }
    }

    @Test
    fun `createBackup on a running instance restores automatic saving when the archive fails`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), "instance data".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val consoleLines = CopyOnWriteArrayList<String>()
        val commandsSent = CopyOnWriteArrayList<String>()
        fakeRunningConsole(instanceId, consoleLines = consoleLines, commandsSent = commandsSent)

        val backupService = newBackupService().apply {
            onReadyToPublish = { throw IOException("simulated publication failure") }
        }

        val exception = assertThrows<ResponseStatusException> {
            backupService.createBackup(instanceId)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR)
        assertThat(exception.reason)
            .contains("Backup failed")
            .contains("try again")
            .contains("save-on command was issued")
            .doesNotContain(instanceDir.toString())
        // save-on is restored even though the backup failed, and the
        // temporary archive is removed again.
        assertThat(commandsSent).containsExactly("save-off", "save-all flush", "save-on")
        Files.list(instanceDir.resolve("backups")).use { entries ->
            assertThat(entries.map { it.name }).isEmpty()
        }
        assertThat(backupService.listBackups(instanceId)).isEmpty()
    }

    @Test
    fun `createBackup on a running instance aborts before writing when the flush confirmation times out`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), "instance data".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        // The server confirms save-off but never the flush, so the protocol
        // cannot complete within the short test timeout.
        val consoleLines = CopyOnWriteArrayList<String>()
        val commandsSent = CopyOnWriteArrayList<String>()
        fakeRunningConsole(
            instanceId,
            confirmableCommands = mapOf("save-off" to "Automatic saving is now disabled"),
            consoleLines = consoleLines,
            commandsSent = commandsSent
        )

        val published = AtomicBoolean(false)
        val backupService = newBackupService(worldSaveConfirmationTimeoutMillis = 400).apply {
            onReadyToPublish = { published.set(true) }
        }

        val before = System.nanoTime()
        val exception = assertThrows<ResponseStatusException> {
            backupService.createBackup(instanceId)
        }
        val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - before)

        assertThat(exception.statusCode).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE)
        assertThat(exception.reason)
            .contains("no backup was created")
            .contains("save-on command was issued")
            .contains("Stop the server and create the backup again")
            .doesNotContain(instanceDir.toString())
            .doesNotContain("level.dat")
        // save-on is restored even on the abort, and nothing was written.
        assertThat(commandsSent).containsExactly("save-off", "save-all flush", "save-on")
        assertThat(published.get()).isFalse()
        assertThat(Files.exists(instanceDir.resolve("backups"))).isFalse()
        assertThat(elapsedMillis).isBetween(200L, 5_000L)
    }

    @Test
    fun `createBackup on a stopped instance does not send console save commands`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val fileBytes = "instance data".toByteArray()
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), fileBytes)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()
        every { processManagerService.isInstanceRunning(instanceId) } returns false

        val backup = newBackupService().createBackup(instanceId)

        verify(exactly = 0) { processManagerService.sendCommand(any(), any()) }
        ZipFile(instanceDir.resolve("backups").resolve(backup.name).toFile()).use { zip ->
            val entry = zip.getEntry("level.dat")
            assertThat(entry).isNotNull
            assertThat(zip.getInputStream(entry).use { it.readAllBytes() }).containsExactly(*fileBytes)
        }
    }

    @Test
    fun `createBackup on a running instance restores automatic saving even when the filesystem cannot back up safely`() {
        // Runs only where SecureDirectoryStream is unsupported: archive writing
        // fails there by design, and this test proves the live coordination
        // still completed and restored automatic saving. On filesystems with
        // secure directory access this failure path cannot be produced.
        assumeSecureDirectoryStreamUnsupported()
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), "instance data".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir

        val consoleLines = CopyOnWriteArrayList<String>()
        val commandsSent = CopyOnWriteArrayList<String>()
        fakeRunningConsole(instanceId, consoleLines = consoleLines, commandsSent = commandsSent)

        val exception = assertThrows<ResponseStatusException> {
            newBackupService().createBackup(instanceId)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR)
        assertThat(exception.reason)
            .contains("secure directory access")
            .contains("try again")
            .contains("save-on command was issued")
        assertThat(commandsSent).containsExactly("save-off", "save-all flush", "save-on")
        assertThat(Files.exists(instanceDir.resolve("backups"))).isFalse()
    }

    @Test
    fun `createBackup publishes the archive only after writing is complete`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        val fileBytes = "instance data".toByteArray()
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), fileBytes)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val readyToPublish = CountDownLatch(1)
        val releasePublish = CountDownLatch(1)
        val publishedBackupName = AtomicReference<String>()
        val backupResult = AtomicReference<Result<BackupEntry>>()
        val backupService = newBackupService().apply {
            onReadyToPublish = { backupName ->
                publishedBackupName.set(backupName)
                readyToPublish.countDown()
                releasePublish.await(10, TimeUnit.SECONDS)
            }
        }

        val runningBackup = thread(start = true) {
            backupResult.set(runCatching { backupService.createBackup(instanceId) })
        }
        assertThat(readyToPublish.await(10, TimeUnit.SECONDS)).isTrue()

        val backupName = publishedBackupName.get()
        assertThat(backupName).isNotNull().endsWith(".zip")
        val visibleNames = Files.list(backupsDir).use { entries -> entries.map { it.name }.toList() }
        assertThat(visibleNames).hasSize(1)
        val temporaryName = visibleNames.first()
        assertThat(temporaryName).startsWith("$backupName.tmp-")
        assertThat(temporaryName).doesNotEndWith(".zip")
        assertThat(backupService.listBackups(instanceId)).isEmpty()
        assertThat(Files.exists(backupsDir.resolve(backupName))).isFalse()

        releasePublish.countDown()
        runningBackup.join(TimeUnit.SECONDS.toMillis(10))
        assertThat(runningBackup.isAlive).isFalse()

        val backup = backupResult.get().getOrThrow()
        assertThat(backup.name).isEqualTo(backupName)
        assertThat(backupService.listBackups(instanceId).map { it.name }).containsExactly(backupName)
        ZipFile(backupsDir.resolve(backupName).toFile()).use { zip ->
            val entry = zip.getEntry("level.dat")
            assertThat(entry).isNotNull
            assertThat(zip.getInputStream(entry).use { it.readAllBytes() }).containsExactly(*fileBytes)
        }
        Files.list(backupsDir).use { entries ->
            assertThat(entries.map { it.name }.toList()).containsExactly(backupName)
        }
    }

    @Test
    fun `createBackup removes the temporary file when writing fails`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        val externalFile = tempDir.resolve("outside.txt")
        val externalContent = "external secret".toByteArray()
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), "safe data".toByteArray())
        Files.write(externalFile, externalContent)
        createSymbolicLinkOrSkip(instanceDir.resolve("external.txt"), externalFile)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val exception = assertThrows<ResponseStatusException> {
            newBackupService().createBackup(instanceId)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
        assertThat(exception.reason)
            .contains("Remove symbolic links")
            .contains("try again")
            .doesNotContain(externalFile.toString())
            .doesNotContain(String(externalContent))
        Files.list(backupsDir).use { entries ->
            assertThat(entries.map { it.name }.toList()).isEmpty()
        }
        assertThat(newBackupService().listBackups(instanceId)).isEmpty()
    }

    @Test
    fun `createBackup keeps existing backups and reports a safe next action when publishing fails`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        val olderBackup = "backup-2026-01-01_00-00-00.zip"
        val olderContent = "older archive".toByteArray()
        Files.createDirectories(backupsDir)
        Files.write(backupsDir.resolve(olderBackup), olderContent)
        Files.write(instanceDir.resolve("level.dat"), "instance data".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val finalBackupName = AtomicReference<String>()
        val backupService = newBackupService().apply {
            onReadyToPublish = { backupName ->
                finalBackupName.set(backupName)
                // A directory at the final name cannot be replaced by renaming a
                // regular file, so publication must fail.
                Files.createDirectories(backupsDir.resolve(backupName))
            }
        }

        val exception = assertThrows<ResponseStatusException> {
            backupService.createBackup(instanceId)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR)
        assertThat(exception.reason)
            .contains("could not be published")
            .contains("No existing backups were changed")
            .contains("try again")
            .doesNotContain(instanceDir.toString())
            .doesNotContain(tempDir.toString())

        val finalName = finalBackupName.get()
        assertThat(Files.isDirectory(backupsDir.resolve(finalName))).isTrue()
        val remainingNames = Files.list(backupsDir).use { entries -> entries.map { it.name }.toList() }
        assertThat(remainingNames).containsExactlyInAnyOrder(olderBackup, finalName)
        assertThat(remainingNames.none { it.contains(".tmp-") }).isTrue()
        assertThat(Files.readAllBytes(backupsDir.resolve(olderBackup))).isEqualTo(olderContent)
        assertThat(newBackupService().listBackups(instanceId).map { it.name }).contains(olderBackup)
    }

    @Test
    fun `listBackups does not report temporary backup files`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        Files.createDirectories(backupsDir)
        Files.write(backupsDir.resolve("backup-2026-01-01_00-00-00.zip"), "finished archive".toByteArray())
        Files.write(
            backupsDir.resolve("backup-2026-01-01_00-00-00.zip.tmp-0f0e0d0c-0b0a-0908-0706-050403020100"),
            "partially written archive".toByteArray()
        )
        every { instanceService.getInstancePath(instanceId) } returns instanceDir

        val backups = newBackupService().listBackups(instanceId)

        assertThat(backups.map { it.name }).containsExactly("backup-2026-01-01_00-00-00.zip")
    }

    @Test
    fun `createBackup rejects symbolic links without leaving an archive`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val externalFile = tempDir.resolve("outside.txt")
        val externalContent = "external secret".toByteArray()
        Files.createDirectories(instanceDir)
        Files.write(instanceDir.resolve("level.dat"), "safe data".toByteArray())
        Files.write(externalFile, externalContent)
        createSymbolicLinkOrSkip(instanceDir.resolve("external.txt"), externalFile)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir

        val exception = assertThrows<ResponseStatusException> {
            newBackupService().createBackup(instanceId)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
        assertThat(exception.reason)
            .contains("Remove symbolic links")
            .doesNotContain(externalFile.toString())
            .doesNotContain(String(externalContent))
        Files.list(instanceDir.resolve("backups")).use { backups ->
            assertThat(backups.toList()).isEmpty()
        }
    }

    @Test
    fun `createBackup rejects symbolic link ancestors without reading outside files`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val externalDir = tempDir.resolve("outside")
        val externalFile = externalDir.resolve("secret.txt")
        val externalContent = "external secret".toByteArray()
        Files.createDirectories(instanceDir)
        Files.createDirectories(externalDir)
        Files.write(externalFile, externalContent)
        createSymbolicLinkOrSkip(instanceDir.resolve("linked-directory"), externalDir)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir

        val exception = assertThrows<ResponseStatusException> {
            newBackupService().createBackup(instanceId)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
        assertThat(exception.reason)
            .contains("Remove symbolic links")
            .doesNotContain(externalFile.toString())
            .doesNotContain(String(externalContent))
        Files.list(instanceDir.resolve("backups")).use { backups ->
            assertThat(backups.toList()).isEmpty()
        }
    }

    @Test
    fun `createBackup rejects a colliding operation on the same instance with a safe conflict error`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        val insideRunningOperation = CountDownLatch(1)
        val finishRunningOperation = CountDownLatch(1)
        every { instanceService.getInstancePath(instanceId) } answers {
            insideRunningOperation.countDown()
            finishRunningOperation.await(10, TimeUnit.SECONDS)
            instanceDir
        }
        val backupService = newBackupService()

        val runningBackup = thread(start = true) {
            runCatching { backupService.createBackup(instanceId) }
        }
        assertThat(insideRunningOperation.await(10, TimeUnit.SECONDS)).isTrue()

        val exception = assertThrows<ResponseStatusException> {
            backupService.createBackup(instanceId)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.CONFLICT)
        assertThat(exception.reason)
            .contains("already running")
            .contains("Wait for it to finish and try again")
            .doesNotContain(instanceDir.toString())
        assertThat(Files.exists(instanceDir.resolve("backups"))).isFalse()

        finishRunningOperation.countDown()
        runningBackup.join(TimeUnit.SECONDS.toMillis(10))
        assertThat(runningBackup.isAlive).isFalse()
    }

    @Test
    fun `deleteBackup rejects a colliding operation while a backup runs on the same instance`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        val existingBackup = "backup-2026-01-01_00-00-00.zip"
        Files.createDirectories(backupsDir)
        Files.write(backupsDir.resolve(existingBackup), "existing archive".toByteArray())
        val insideRunningOperation = CountDownLatch(1)
        val finishRunningOperation = CountDownLatch(1)
        every { instanceService.getInstancePath(instanceId) } answers {
            insideRunningOperation.countDown()
            finishRunningOperation.await(10, TimeUnit.SECONDS)
            instanceDir
        }
        val backupService = newBackupService()

        val runningBackup = thread(start = true) {
            runCatching { backupService.createBackup(instanceId) }
        }
        assertThat(insideRunningOperation.await(10, TimeUnit.SECONDS)).isTrue()

        val exception = assertThrows<ResponseStatusException> {
            backupService.deleteBackup(instanceId, existingBackup)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.CONFLICT)
        assertThat(exception.reason)
            .contains("already running")
            .contains("Wait for it to finish and try again")
        assertThat(Files.exists(backupsDir.resolve(existingBackup))).isTrue()

        finishRunningOperation.countDown()
        runningBackup.join(TimeUnit.SECONDS.toMillis(10))
        assertThat(runningBackup.isAlive).isFalse()
    }

    @Test
    fun `backup operations on different instances do not block each other`() {
        val blockedInstanceId = UUID.randomUUID()
        val blockedInstanceDir = tempDir.resolve("instance-blocked")
        Files.createDirectories(blockedInstanceDir)
        val otherInstanceId = UUID.randomUUID()
        val otherInstanceDir = tempDir.resolve("instance-other")
        val otherBackupsDir = otherInstanceDir.resolve("backups")
        val otherBackupName = "backup-2026-01-02_00-00-00.zip"
        Files.createDirectories(otherBackupsDir)
        Files.write(otherBackupsDir.resolve(otherBackupName), "other archive".toByteArray())
        val insideRunningOperation = CountDownLatch(1)
        val finishRunningOperation = CountDownLatch(1)
        every { instanceService.getInstancePath(blockedInstanceId) } answers {
            insideRunningOperation.countDown()
            finishRunningOperation.await(10, TimeUnit.SECONDS)
            blockedInstanceDir
        }
        every { instanceService.getInstancePath(otherInstanceId) } returns otherInstanceDir
        val backupService = newBackupService()

        val runningBackup = thread(start = true) {
            runCatching { backupService.createBackup(blockedInstanceId) }
        }
        assertThat(insideRunningOperation.await(10, TimeUnit.SECONDS)).isTrue()

        backupService.deleteBackup(otherInstanceId, otherBackupName)

        assertThat(Files.exists(otherBackupsDir.resolve(otherBackupName))).isFalse()

        finishRunningOperation.countDown()
        runningBackup.join(TimeUnit.SECONDS.toMillis(10))
        assertThat(runningBackup.isAlive).isFalse()
    }

    @Test
    fun `deleteBackup removes the requested backup and succeeds again on the next call`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        val firstBackup = "backup-2026-01-03_00-00-00.zip"
        val secondBackup = "backup-2026-01-04_00-00-00.zip"
        Files.createDirectories(backupsDir)
        Files.write(backupsDir.resolve(firstBackup), "first archive".toByteArray())
        Files.write(backupsDir.resolve(secondBackup), "second archive".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir

        val backupService = newBackupService()
        backupService.deleteBackup(instanceId, firstBackup)
        assertThat(Files.exists(backupsDir.resolve(firstBackup))).isFalse()
        assertThat(Files.exists(backupsDir.resolve(secondBackup))).isTrue()

        backupService.deleteBackup(instanceId, "backup-unknown_00-00-00.zip")
        assertThat(Files.exists(backupsDir.resolve(secondBackup))).isTrue()
    }

    // ------------------------------------------------------------------
    // Restore
    // ------------------------------------------------------------------

    @Test
    fun `restoreBackup replaces the instance data with the archived set and leaves no staging entries`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v1".toByteArray())
        Files.createDirectories(instanceDir.resolve("mods"))
        Files.write(instanceDir.resolve("mods").resolve("coolmod.jar"), "mod bytes".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val backup = newBackupService().createBackup(instanceId)
        val instanceJsonBytes = Files.readAllBytes(instanceDir.resolve("instance.json"))

        // Data that was changed or added after the backup must not survive a restore.
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v2 (corrupted)".toByteArray())
        Files.createDirectories(instanceDir.resolve("world").resolve("region"))
        Files.write(instanceDir.resolve("world").resolve("region").resolve("r.0.0.mca"), "region".toByteArray())
        Files.write(instanceDir.resolve("mods").resolve("newmod.jar"), "new mod".toByteArray())
        Files.write(instanceDir.resolve("stray-file.txt"), "added after the backup".toByteArray())

        newBackupService().restoreBackup(instanceId, backup.name)

        assertThat(Files.readAllBytes(instanceDir.resolve("instance.json"))).isEqualTo(instanceJsonBytes)
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data v1".toByteArray())
        assertThat(Files.readAllBytes(instanceDir.resolve("mods").resolve("coolmod.jar")))
            .isEqualTo("mod bytes".toByteArray())
        // Full-set semantics: entries that the archive does not carry are removed.
        assertThat(Files.exists(instanceDir.resolve("world").resolve("region"))).isFalse()
        assertThat(Files.exists(instanceDir.resolve("mods").resolve("newmod.jar"))).isFalse()
        assertThat(Files.exists(instanceDir.resolve("stray-file.txt"))).isFalse()
        // The backups directory is preserved and no restore working entry remains.
        assertThat(Files.exists(instanceDir.resolve("backups").resolve(backup.name))).isTrue()
        assertThat(listInstanceEntryNames(instanceDir))
            .containsExactlyInAnyOrder("backups", "instance.json", "world", "mods")
        assertNoRestoreWorkingEntries(instanceDir)
    }

    @Test
    fun `restoreBackup rejects colliding backup operations while a restore runs`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v1".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val backup = newBackupService().createBackup(instanceId)
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v2 (corrupted)".toByteArray())

        val insideRestore = CountDownLatch(1)
        val releaseRestore = CountDownLatch(1)
        val firstPublish = AtomicBoolean(true)
        val restoreResult = AtomicReference<Result<Unit>>()
        val backupService = newBackupService().apply {
            onBeforePublishRestoreEntry = { _ ->
                if (firstPublish.getAndSet(false)) {
                    insideRestore.countDown()
                    releaseRestore.await(10, TimeUnit.SECONDS)
                }
            }
        }
        val runningRestore = thread(start = true) {
            restoreResult.set(runCatching { backupService.restoreBackup(instanceId, backup.name) })
        }
        assertThat(insideRestore.await(10, TimeUnit.SECONDS)).isTrue()
        // The restore holds the backup operation lock while it works: the
        // replaced data is already aside and the staged archive waits in the
        // staging directory for the adoption.
        assertThat(listInstanceEntryNames(instanceDir).any { it.startsWith(".restore-aside-") }).isTrue()
        assertThat(listInstanceEntryNames(instanceDir).any { it.startsWith(".restore-staging-") }).isTrue()

        val deleteException = assertThrows<ResponseStatusException> {
            backupService.deleteBackup(instanceId, backup.name)
        }
        val createException = assertThrows<ResponseStatusException> {
            backupService.createBackup(instanceId)
        }

        assertThat(deleteException.statusCode).isEqualTo(HttpStatus.CONFLICT)
        assertThat(createException.statusCode).isEqualTo(HttpStatus.CONFLICT)
        assertThat(createException.reason)
            .contains("already running")
            .contains("Wait for it to finish and try again")
            .doesNotContain(instanceDir.toString())
        assertThat(Files.exists(instanceDir.resolve("backups").resolve(backup.name))).isTrue()

        releaseRestore.countDown()
        runningRestore.join(TimeUnit.SECONDS.toMillis(10))
        assertThat(runningRestore.isAlive).isFalse()
        restoreResult.get().getOrThrow()
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data v1".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)
    }

    @Test
    fun `restoreBackup rejects with conflict while a backup operation runs on the same instance`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        val archiveName = "backup-2026-01-05_00-00-00.zip"
        Files.createDirectories(backupsDir)
        Files.write(backupsDir.resolve(archiveName), "existing archive".toByteArray())
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data".toByteArray())
        val insideRunningOperation = CountDownLatch(1)
        val finishRunningOperation = CountDownLatch(1)
        every { instanceService.getInstancePath(instanceId) } answers {
            insideRunningOperation.countDown()
            finishRunningOperation.await(10, TimeUnit.SECONDS)
            instanceDir
        }
        val backupService = newBackupService()

        val runningBackup = thread(start = true) {
            runCatching { backupService.createBackup(instanceId) }
        }
        assertThat(insideRunningOperation.await(10, TimeUnit.SECONDS)).isTrue()

        val exception = assertThrows<ResponseStatusException> {
            backupService.restoreBackup(instanceId, archiveName)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.CONFLICT)
        assertThat(exception.reason)
            .contains("already running")
            .contains("Wait for it to finish and try again")
            .doesNotContain(instanceDir.toString())
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)

        finishRunningOperation.countDown()
        runningBackup.join(TimeUnit.SECONDS.toMillis(10))
        assertThat(runningBackup.isAlive).isFalse()
    }

    @Test
    fun `restoreBackup rejects unsafe archives before extraction and leaves the instance data untouched`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data".toByteArray())
        Files.createDirectories(instanceDir.resolve("backups"))
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val cases = listOf(
            "world/../../../outside-evil.txt" to "parent-directory",
            "/outside-evil.txt" to "absolute path",
            "C:/outside-evil.txt" to "absolute path",
            "world\\..\\outside-evil.txt" to "unsupported path separator",
            "backups/planted.zip" to "protected backups directory",
        )
        cases.forEachIndexed { index, (entryName, expectedReason) ->
            val archiveName = "backup-unsafe-$index.zip"
            writeZip(
                instanceDir.resolve("backups").resolve(archiveName),
                descriptionId = instanceId,
                entries = mapOf(entryName to "archive-controlled content")
            )

            val exception = assertThrows<ResponseStatusException> {
                newBackupService().restoreBackup(instanceId, archiveName)
            }

            assertThat(exception.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
            assertThat(exception.reason)
                .contains("not a safe instance backup")
                .contains(expectedReason)
                .contains("Remove this backup")
                .doesNotContain(entryName)
                .doesNotContain("archive-controlled content")
                .doesNotContain(instanceDir.toString())
            // The rejection happened before extraction: existing data and the
            // surroundings are untouched, no traversal file was created.
            assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
                .isEqualTo("world data".toByteArray())
            assertThat(Files.exists(tempDir.resolve("outside-evil.txt"))).isFalse()
            assertNoRestoreWorkingEntries(instanceDir)
        }
    }

    @Test
    fun `restoreBackup materializes declared link entries as regular files so links cannot escape`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("backups"))
        val outsideFile = tempDir.resolve("outside-secret.txt")
        Files.write(outsideFile, "outside data".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val archiveName = "backup-2026-01-06_00-00-00.zip"
        writeRawStoredZip(
            instanceDir.resolve("backups").resolve(archiveName),
            listOf(
                Triple("instance.json", """{"id":"$instanceId","name":"restore-test"}""".toByteArray(), 0),
                // 41471 = 0120777 octal: Unix symlink mode in the external attributes.
                Triple("linked-file", outsideFile.fileName.toString().toByteArray(), 41471 shl 16)
            )
        )

        newBackupService().restoreBackup(instanceId, archiveName)

        // The declared symlink became a regular file whose content is the
        // stored target text; no link was created and the outside file is
        // unchanged.
        val linkedFile = instanceDir.resolve("linked-file")
        assertThat(Files.isSymbolicLink(linkedFile)).isFalse()
        assertThat(
            Files.readAttributes(linkedFile, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
                .isRegularFile
        ).isTrue()
        assertThat(Files.readAllBytes(linkedFile)).isEqualTo(outsideFile.fileName.toString().toByteArray())
        assertThat(Files.readAllBytes(outsideFile)).isEqualTo("outside data".toByteArray())
        assertThat(Files.exists(instanceDir.resolve("instance.json"))).isTrue()
        assertNoRestoreWorkingEntries(instanceDir)
    }

    @Test
    fun `restoreBackup rolls back the previous instance data when the adoption fails`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v1".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val backup = newBackupService().createBackup(instanceId)
        val instanceJsonBytes = Files.readAllBytes(instanceDir.resolve("instance.json"))
        // State after the backup: corrupted world data plus added entries.
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v2 (corrupted)".toByteArray())
        Files.createDirectories(instanceDir.resolve("world").resolve("region"))
        Files.write(instanceDir.resolve("world").resolve("region").resolve("r.0.0.mca"), "region".toByteArray())
        Files.createDirectories(instanceDir.resolve("mods"))
        Files.write(instanceDir.resolve("mods").resolve("newmod.jar"), "new mod".toByteArray())
        Files.write(instanceDir.resolve("stray-file.txt"), "added after the backup".toByteArray())

        val backupService = newBackupService().apply {
            onBeforePublishRestoreEntry = { entryName ->
                if (entryName == "world") throw IOException("simulated adoption failure")
            }
        }

        val exception = assertThrows<ResponseStatusException> {
            backupService.restoreBackup(instanceId, backup.name)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR)
        assertThat(exception.reason)
            .contains("previous instance data was moved back")
            .contains("no partial changes remain")
            .contains("try again")
            .doesNotContain(instanceDir.toString())
            .doesNotContain("simulated adoption failure")
        // The complete pre-restore state is back in place.
        assertThat(Files.readAllBytes(instanceDir.resolve("instance.json"))).isEqualTo(instanceJsonBytes)
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data v2 (corrupted)".toByteArray())
        assertThat(Files.exists(instanceDir.resolve("world").resolve("region").resolve("r.0.0.mca"))).isTrue()
        assertThat(Files.readAllBytes(instanceDir.resolve("mods").resolve("newmod.jar")))
            .isEqualTo("new mod".toByteArray())
        assertThat(Files.exists(instanceDir.resolve("stray-file.txt"))).isTrue()
        assertThat(listInstanceEntryNames(instanceDir))
            .containsExactlyInAnyOrder("backups", "instance.json", "world", "mods", "stray-file.txt")
        assertNoRestoreWorkingEntries(instanceDir)
        assertThat(Files.exists(instanceDir.resolve("backups").resolve(backup.name))).isTrue()
    }

    @Test
    fun `restoreBackup on a running instance is blocked with a guided conflict and sends no console commands`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()
        // The process manager's restore gate refuses a live game server; that
        // the gate really refuses a running instance is proven against the
        // real process manager in ProcessManagerServiceTest and in the
        // end-to-end RestoreProcessGuardTest.
        every { processManagerService.beginRestore(instanceId) } returns false

        val exception = assertThrows<ResponseStatusException> {
            newBackupService().restoreBackup(instanceId, "backup-2026-01-05_00-00-00.zip")
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.CONFLICT)
        assertThat(exception.reason)
            .contains("running")
            .contains("Stop the instance in the console")
            .contains("STOPPED")
            .contains("retry the restore")
            .contains("No instance data was changed")
            .doesNotContain(instanceDir.toString())
        // Blocking is the guard's whole action: the orderly stop stays an
        // explicit user action, so no command reaches the game server — in
        // particular no automatic stop — and the data remains untouched.
        verify(exactly = 0) { processManagerService.sendCommand(any(), any()) }
        // No reservation was taken, so none is released.
        verify(exactly = 0) { processManagerService.endRestore(instanceId) }
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)
    }

    @Test
    fun `restoreBackup runs under the restore reservation and releases it afterwards`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v1".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val backup = newBackupService().createBackup(instanceId)
        newBackupService().restoreBackup(instanceId, backup.name)

        verifyOrder {
            processManagerService.beginRestore(instanceId)
            processManagerService.endRestore(instanceId)
        }
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data v1".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)
    }

    @Test
    fun `restoreBackup releases the restore reservation on failure so a retry can take it again`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v1".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val backup = newBackupService().createBackup(instanceId)
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data v2 (corrupted)".toByteArray())

        val backupService = newBackupService().apply {
            onBeforePublishRestoreEntry = { entryName ->
                if (entryName == "world") throw IOException("simulated adoption failure")
            }
        }

        val exception = assertThrows<ResponseStatusException> {
            backupService.restoreBackup(instanceId, backup.name)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR)
        // The failed restore released its reservation in every path, so the
        // retry was accepted by the gate again and completed.
        verify(exactly = 1) { processManagerService.endRestore(instanceId) }

        backupService.onBeforePublishRestoreEntry = null
        backupService.restoreBackup(instanceId, backup.name)

        verify(exactly = 2) { processManagerService.beginRestore(instanceId) }
        verify(exactly = 2) { processManagerService.endRestore(instanceId) }
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data v1".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)
    }

    @Test
    fun `restoreBackup reports a missing backup with a guided error`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val exception = assertThrows<ResponseStatusException> {
            newBackupService().restoreBackup(instanceId, "backup-2099-01-01_00-00-00.zip")
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.NOT_FOUND)
        assertThat(exception.reason)
            .contains("No backup with this name exists")
            .contains("Refresh the backup list")
            .doesNotContain(instanceDir.toString())
        assertThat(listInstanceEntryNames(instanceDir)).containsExactly("instance.json")
    }

    @Test
    fun `restoreBackup rejects a corrupted or empty archive and leaves the instance data untouched`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        Files.createDirectories(backupsDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data".toByteArray())
        // A valid STORED archive whose stored data was flipped afterwards, so
        // the stored CRC no longer matches the content.
        val corruptArchive = backupsDir.resolve("backup-corrupt.zip")
        val corruptedContent = "world data that must be corrupted uniquely"
        writeZip(corruptArchive, descriptionId = instanceId, entries = mapOf("world/level.dat" to corruptedContent))
        val archiveBytes = Files.readAllBytes(corruptArchive)
        val contentBytes = corruptedContent.toByteArray()
        val contentOffset = (0..archiveBytes.size - contentBytes.size)
            .firstOrNull { offset -> (0 until contentBytes.size).all { archiveBytes[offset + it] == contentBytes[it] } }
            ?: throw AssertionError("Stored content not found verbatim in the archive fixture")
        archiveBytes[contentOffset] = (archiveBytes[contentOffset].toInt() xor 0xFF).toByte()
        Files.write(corruptArchive, archiveBytes)
        ZipOutputStream(Files.newOutputStream(backupsDir.resolve("backup-empty.zip"))).use { /* no entries */ }
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val corruptException = assertThrows<ResponseStatusException> {
            newBackupService().restoreBackup(instanceId, "backup-corrupt.zip")
        }
        val emptyException = assertThrows<ResponseStatusException> {
            newBackupService().restoreBackup(instanceId, "backup-empty.zip")
        }

        assertThat(corruptException.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
        assertThat(corruptException.reason)
            .contains("could not be read as an archive")
            .contains("not changed")
            .doesNotContain(instanceDir.toString())
        assertThat(emptyException.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
        assertThat(emptyException.reason)
            .contains("not a complete instance backup")
            .doesNotContain(instanceDir.toString())
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)
    }

    @Test
    fun `restoreBackup rejects an invalid backup name`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        Files.createDirectories(instanceDir)
        writeInstanceDescription(instanceDir, instanceId)
        every { instanceService.getInstancePath(instanceId) } returns instanceDir

        for (name in listOf("..", "..\\backup.zip", "sub/backup.zip", "", " ", ".", "backup.zip/", "/backup.zip")) {
            val exception = assertThrows<ResponseStatusException> {
                newBackupService().restoreBackup(instanceId, name)
            }

            assertThat(exception.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
            assertThat(exception.reason)
                .contains("backup name is invalid")
                .doesNotContain(instanceDir.toString())
        }
        assertThat(listInstanceEntryNames(instanceDir)).containsExactly("instance.json")
    }

    @Test
    fun `restoreBackup rejects an archive that belongs to a different instance`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        Files.createDirectories(backupsDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val archiveName = "backup-2026-01-07_00-00-00.zip"
        writeZip(
            backupsDir.resolve(archiveName),
            descriptionId = UUID.randomUUID(),
            entries = mapOf("world/level.dat" to "planted world data")
        )

        val exception = assertThrows<ResponseStatusException> {
            newBackupService().restoreBackup(instanceId, archiveName)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
        assertThat(exception.reason)
            .contains("belongs to a different instance")
            .contains("Choose a backup")
            .doesNotContain(instanceDir.toString())
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)
    }

    @Test
    fun `restoreBackup rejects an archive with duplicate normalized entries`() {
        val instanceId = UUID.randomUUID()
        val instanceDir = tempDir.resolve("instance")
        val backupsDir = instanceDir.resolve("backups")
        Files.createDirectories(backupsDir)
        writeInstanceDescription(instanceDir, instanceId)
        Files.createDirectories(instanceDir.resolve("world"))
        Files.write(instanceDir.resolve("world").resolve("level.dat"), "world data".toByteArray())
        every { instanceService.getInstancePath(instanceId) } returns instanceDir
        assumeSecureDirectoryStreamSupported()

        val archiveName = "backup-2026-01-08_00-00-00.zip"
        ZipOutputStream(BufferedOutputStream(Files.newOutputStream(backupsDir.resolve(archiveName)))).use { zip ->
            zip.putNextEntry(ZipEntry("instance.json"))
            zip.write("""{"id":"$instanceId","name":"restore-test"}""".toByteArray())
            zip.closeEntry()
            zip.putNextEntry(ZipEntry("world/level.dat"))
            zip.write("world data".toByteArray())
            zip.closeEntry()
            // The raw name differs only by a harmless current-directory
            // component, but it normalizes to the same entry path as the one
            // above, which the validation pass must reject as a conflict.
            zip.putNextEntry(ZipEntry("./world/level.dat"))
            zip.write("conflicting duplicate content".toByteArray())
            zip.closeEntry()
        }

        val exception = assertThrows<ResponseStatusException> {
            newBackupService().restoreBackup(instanceId, archiveName)
        }

        assertThat(exception.statusCode).isEqualTo(HttpStatus.BAD_REQUEST)
        assertThat(exception.reason)
            .contains("conflicting duplicate entries")
            .contains("Remove this backup")
            .doesNotContain("world/level.dat")
            .doesNotContain("conflicting duplicate content")
            .doesNotContain(instanceDir.toString())
        // The rejection happened in the validation pass before anything was
        // unpacked: existing data is untouched and no staging entry exists.
        assertThat(Files.readAllBytes(instanceDir.resolve("world").resolve("level.dat")))
            .isEqualTo("world data".toByteArray())
        assertNoRestoreWorkingEntries(instanceDir)
    }

    private val objectMapper: ObjectMapper = jacksonObjectMapper()

    private fun newBackupService(
        instanceBackupOperationLocks: InstanceBackupOperationLocks = InstanceBackupOperationLocks(),
        worldSaveConfirmationTimeoutMillis: Long = 60_000
    ): BackupService = BackupService(
        instanceService,
        processManagerService,
        instanceBackupOperationLocks,
        logger,
        objectMapper,
        worldSaveConfirmationTimeoutMillis
    )

    /**
     * Fakes the console interaction of a running server: every command sent
     * through the process manager is echoed into the console buffer like the
     * real reader does, and the vanilla confirmation lines are appended for
     * the commands that are listed as confirmable. Commands without an entry
     * here stay unconfirmed, which drives the timeout path of the protocol.
     */
    private fun fakeRunningConsole(
        instanceId: UUID,
        confirmableCommands: Map<String, String> = mapOf(
            "save-off" to "Automatic saving is now disabled",
            "save-all flush" to "Saved the game"
        ),
        consoleLines: CopyOnWriteArrayList<String> = CopyOnWriteArrayList(),
        commandsSent: CopyOnWriteArrayList<String> = CopyOnWriteArrayList()
    ) {
        every { processManagerService.isInstanceRunning(instanceId) } returns true
        every { processManagerService.sendCommand(instanceId, any()) } answers {
            val command = arg<String>(1)
            commandsSent.add(command)
            consoleLines.add("> $command")
            confirmableCommands[command]?.let { consoleLines.add(it) }
            Unit
        }
        every { processManagerService.getLogSnapshot(instanceId) } answers { consoleLines.toList() }
    }

    private fun createSymbolicLinkOrSkip(link: Path, target: Path) {
        val result = runCatching { Files.createSymbolicLink(link, target) }
        assumeTrue(result.isSuccess, "This filesystem does not support creating symbolic links")
    }

    private fun assumeSecureDirectoryStreamSupported() {
        val supported = Files.newDirectoryStream(tempDir).use { it is SecureDirectoryStream<*> }
        assumeTrue(
            supported,
            "SecureDirectoryStream is not supported on this platform; backup creation fails there by design"
        )
    }

    private fun assumeSecureDirectoryStreamUnsupported() {
        val supported = Files.newDirectoryStream(tempDir).use { it is SecureDirectoryStream<*> }
        assumeTrue(
            !supported,
            "SecureDirectoryStream is supported here; the unsafe-filesystem failure path cannot be produced"
        )
    }

    private fun writeInstanceDescription(instanceDir: Path, instanceId: UUID) {
        Files.write(
            instanceDir.resolve("instance.json"),
            """{"id":"$instanceId","name":"restore-test"}""".toByteArray()
        )
    }

    private fun listInstanceEntryNames(instanceDir: Path): List<String> =
        Files.list(instanceDir).use { entries -> entries.map { it.fileName.toString() }.toList() }

    private fun assertNoRestoreWorkingEntries(instanceDir: Path) {
        val workingEntries = listInstanceEntryNames(instanceDir)
            .filter { it.startsWith(".restore-staging-") || it.startsWith(".restore-aside-") }
        assertThat(workingEntries).isEmpty()
    }

    private fun writeZip(target: Path, descriptionId: UUID?, entries: Map<String, String>) {
        // STORED entries keep their content verbatim in the archive file, so a
        // test can flip a byte inside the stored data to break the CRC. The
        // CRC and size must be set on the entry before writing.
        ZipOutputStream(BufferedOutputStream(Files.newOutputStream(target))).use { zip ->
            if (descriptionId != null) {
                val description = """{"id":"$descriptionId","name":"restore-test"}""".toByteArray()
                writeStoredZipEntry(zip, "instance.json", description)
            }
            for ((entryName, content) in entries) {
                writeStoredZipEntry(zip, entryName, content.toByteArray())
            }
        }
    }

    private fun writeStoredZipEntry(zip: ZipOutputStream, entryName: String, content: ByteArray) {
        val entry = ZipEntry(entryName).apply {
            method = ZipEntry.STORED
            size = content.size.toLong()
            compressedSize = content.size.toLong()
            crc = CRC32().apply { update(content) }.value
        }
        zip.putNextEntry(entry)
        zip.write(content)
        zip.closeEntry()
    }

    /**
     * Writes a minimal STORED zip whose central directory carries explicit
     * Unix external attributes per entry, like a tool that archives symbolic
     * links would produce for a link entry. All multi-byte fields are written
     * little-endian like the zip format requires. java.util.zip reads the
     * entry as plain bytes, so the restore must materialize it as a regular
     * file.
     */
    private fun writeRawStoredZip(target: Path, entries: List<Triple<String, ByteArray, Int>>) {
        fun DataOutputStream.writeLeShort(value: Int) {
            write(value and 0xFF)
            write((value shr 8) and 0xFF)
        }
        fun DataOutputStream.writeLeInt(value: Int) {
            writeLeShort(value and 0xFFFF)
            writeLeShort((value shr 16) and 0xFFFF)
        }
        DataOutputStream(BufferedOutputStream(Files.newOutputStream(target))).use { out ->
            val offsets = ArrayList<Int>()
            var written = 0
            for ((entryName, content, _) in entries) {
                val nameBytes = entryName.toByteArray()
                val crc = CRC32().apply { update(content) }.value
                out.writeLeInt(0x04034b50) // local file header signature
                out.writeLeShort(20) // version needed
                out.writeLeShort(0) // flags
                out.writeLeShort(0) // method STORED
                out.writeLeShort(0) // mod time
                out.writeLeShort(0) // mod date
                out.writeLeInt(crc.toInt())
                out.writeLeInt(content.size)
                out.writeLeInt(content.size)
                out.writeLeShort(nameBytes.size)
                out.writeLeShort(0) // extra length
                out.write(nameBytes)
                out.write(content)
                offsets.add(written)
                written += 30 + nameBytes.size + content.size
            }
            val centralStart = written
            entries.forEachIndexed { index, (entryName, content, externalAttributes) ->
                val nameBytes = entryName.toByteArray()
                val crc = CRC32().apply { update(content) }.value
                out.writeLeInt(0x02014b50) // central directory signature
                out.writeLeShort(0x0314) // version made by: unix
                out.writeLeShort(20) // version needed
                out.writeLeShort(0) // flags
                out.writeLeShort(0) // method STORED
                out.writeLeShort(0) // mod time
                out.writeLeShort(0) // mod date
                out.writeLeInt(crc.toInt())
                out.writeLeInt(content.size)
                out.writeLeInt(content.size)
                out.writeLeShort(nameBytes.size)
                out.writeLeShort(0) // extra length
                out.writeLeShort(0) // comment length
                out.writeLeShort(0) // disk number start
                out.writeLeShort(0) // internal attributes
                out.writeLeInt(externalAttributes)
                out.writeLeInt(offsets[index])
                out.write(nameBytes)
                written += 46 + nameBytes.size
            }
            out.writeLeInt(0x06054b50) // end of central directory signature
            out.writeLeShort(0) // this disk
            out.writeLeShort(0) // disk with the central directory
            out.writeLeShort(entries.size)
            out.writeLeShort(entries.size)
            out.writeLeInt(written - centralStart)
            out.writeLeInt(centralStart)
            out.writeLeShort(0) // comment length
        }
    }
}

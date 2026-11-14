package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.dto.BackupEntry
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.beans.factory.annotation.Value
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.nio.channels.Channels
import java.nio.file.FileAlreadyExistsException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.OpenOption
import java.nio.file.Path
import java.nio.file.SecureDirectoryStream
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributeView
import java.nio.file.attribute.BasicFileAttributes
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipException
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import kotlin.io.path.fileSize
import kotlin.io.path.getLastModifiedTime
import kotlin.io.path.name

@Service
class BackupService(
    private val instanceService: InstanceService,
    private val processManagerService: ProcessManagerService,
    private val instanceBackupOperationLocks: InstanceBackupOperationLocks,
    private val logger: Logger,
    private val objectMapper: ObjectMapper,
    @Value("\${moddex.backup.world-save-confirmation-timeout-ms:60000}")
    private val worldSaveConfirmationTimeoutMillis: Long = 60_000
) {
    init {
        require(worldSaveConfirmationTimeoutMillis > 0) {
            "World save confirmation timeout must be greater than zero"
        }
    }

    private val dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss")

    companion object {
        /**
         * Console protocol for backing up a running world: automatic saving is
         * paused, the world data is flushed to disk, the archive is written,
         * and automatic saving is restored afterwards in every exit path. The
         * confirmations are the dedicated-server console responses of vanilla
         * Minecraft, which the loaders also print for these commands.
         */
        private const val SAVE_OFF_COMMAND = "save-off"
        private const val SAVE_ON_COMMAND = "save-on"
        private const val SAVE_ALL_FLUSH_COMMAND = "save-all flush"
        private const val SAVE_OFF_CONFIRMATION = "Automatic saving is now disabled"
        private const val SAVE_ALL_CONFIRMATION = "Saved the game"

        /** The console reader echoes every command sent to the server like this. */
        private const val CONSOLE_ECHO_PREFIX = "> "

        /** How often the console snapshot is checked for a pending confirmation. */
        private const val CONFIRMATION_POLL_MILLIS = 50L

        private const val LIVE_WORLD_SAVE_ON_NOTICE =
            " A save-on command was issued to restore automatic saving of the running world."

        /** The per-instance directory that holds published backup archives. */
        private const val BACKUPS_DIRECTORY_NAME = "backups"

        /**
         * The instance description entry a backup archive always carries; the
         * restore requires it to identify the archive's instance.
         */
        private const val INSTANCE_DESCRIPTION_ENTRY = "instance.json"

        /** Upper bound for reading the archived instance description in memory. */
        private const val INSTANCE_DESCRIPTION_MAX_BYTES = 1 shl 20

        /** Prefix of the temporary extraction directory of a running restore. */
        private const val RESTORE_STAGING_PREFIX = ".restore-staging-"

        /** Prefix of the entries that temporarily hold the replaced data. */
        private const val RESTORE_ASIDE_PREFIX = ".restore-aside-"

        /**
         * Windows drive-letter prefixes in archive entry names; the restore
         * rejects them on every platform so a crafted archive cannot address
         * another drive root on a Windows host.
         */
        private val ARCHIVE_DRIVE_PREFIX = Regex("^[A-Za-z]:")
    }

    /**
     * Test seam: invoked with the final backup name after the temporary archive
     * is fully written and verified, immediately before it is published. Null in
     * production use; tests use it to observe or obstruct the publication step.
     */
    internal var onReadyToPublish: ((backupName: String) -> Unit)? = null

    fun listBackups(instanceId: UUID): List<BackupEntry> {
        val backupDir = getBackupDir(instanceId)
        if (!Files.exists(backupDir)) return emptyList()

        return Files.list(backupDir)
            .filter { it.toString().endsWith(".zip") }
            .map {
                BackupEntry(
                    name = it.name,
                    size = it.fileSize(),
                    timestamp = it.getLastModifiedTime().toMillis()
                )
            }
            .toList()
            .sortedByDescending { it.timestamp }
    }

    fun createBackup(instanceId: UUID): BackupEntry {
        return instanceBackupOperationLocks.withLock(instanceId) { performCreateBackup(instanceId) }
    }

    /**
     * Writes the archive to a temporary file that [listBackups] cannot report,
     * verifies it, and publishes it under its final name with a controlled
     * rename only after the write has completed. On every failure the temporary
     * file is removed and previously published backups remain untouched.
     *
     * For a running game server the world is saved consistently first: the
     * server confirms [SAVE_OFF_COMMAND] and [SAVE_ALL_FLUSH_COMMAND] through
     * the console before any archive is written, and [SAVE_ON_COMMAND] is sent
     * again in every exit path of the backup, because a save-off may have
     * reached the server even when its confirmation did not. A backup of a
     * stopped instance skips this coordination.
     */
    private fun performCreateBackup(instanceId: UUID): BackupEntry {
        val instanceDir = instanceService.getInstancePath(instanceId)
        val backupDir = instanceDir.resolve("backups")

        val timestamp = LocalDateTime.now().format(dateTimeFormatter)
        val backupName = "backup-$timestamp.zip"
        val temporaryName = "$backupName.tmp-${UUID.randomUUID()}"
        val backupNamePath = backupDir.fileSystem.getPath(backupName)
        val temporaryNamePath = backupDir.fileSystem.getPath(temporaryName)
        var secureBackupDirectory: SecureDirectoryStream<Path>? = null
        var temporaryFileOpened = false
        var backupAttributes: BasicFileAttributes? = null
        // One decision per backup, taken under the instance's backup operation
        // lock: a live world is archived only after a confirmed save pause, and
        // save-on is restored in every exit path once coordination started.
        val coordinatingLiveWorld = processManagerService.isInstanceRunning(instanceId)

        try {
            if (coordinatingLiveWorld) {
                logger.info(
                    "Instance $instanceId is running; pausing automatic saving and flushing world data for a consistent backup"
                )
                awaitConsoleConfirmation(instanceId, SAVE_OFF_COMMAND, SAVE_OFF_CONFIRMATION)
                awaitConsoleConfirmation(instanceId, SAVE_ALL_FLUSH_COMMAND, SAVE_ALL_CONFIRMATION)
            }
            openSecureInstanceDirectory(instanceDir).use { secureInstanceDirectory ->
                Files.createDirectories(backupDir)
                secureBackupDirectory = openSecureChildDirectory(
                    secureInstanceDirectory,
                    backupDir.fileName
                )
                val output = secureBackupDirectory!!.newByteChannel(
                    temporaryNamePath,
                    setOf<OpenOption>(
                        StandardOpenOption.CREATE_NEW,
                        StandardOpenOption.WRITE,
                        LinkOption.NOFOLLOW_LINKS
                    )
                )
                temporaryFileOpened = true
                ZipOutputStream(BufferedOutputStream(Channels.newOutputStream(output))).use { zos ->
                    addDirectoryToZip(
                        secureInstanceDirectory,
                        instanceDir.fileSystem.getPath(""),
                        zos
                    )
                }
                val temporaryAttributes = readAttributes(secureBackupDirectory!!, temporaryNamePath)
                if (!temporaryAttributes.isRegularFile) throw IOException("Backup file is not regular")
                backupAttributes = temporaryAttributes
                onReadyToPublish?.invoke(backupName)
                publishBackupFile(
                    backupDir.resolve(temporaryName),
                    backupDir.resolve(backupName)
                )
            }
        } catch (e: Exception) {
            logger.error("Backup failed")
            if (temporaryFileOpened) {
                secureBackupDirectory?.let { directory ->
                    runCatching { directory.deleteFile(temporaryNamePath) }
                }
            }
            val liveWorldNotice = if (coordinatingLiveWorld) LIVE_WORLD_SAVE_ON_NOTICE else ""
            if (e is WorldSaveConfirmationTimeoutException) {
                logger.error(
                    "Live backup aborted: the server did not confirm '${e.command}' within the configured timeout"
                )
                throw ResponseStatusException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "The running server did not confirm the world save in time, so no backup was created and " +
                        "no archive was published. A save-on command was issued to restore automatic saving. " +
                        "Stop the server and create the backup again, or try again later while the server is running."
                )
            }
            if (e is UnsupportedBackupSymbolicLinkException) {
                throw ResponseStatusException(
                    HttpStatus.BAD_REQUEST,
                    "Backup cannot include symbolic links. Remove symbolic links from the instance directory and try again.$liveWorldNotice"
                )
            }
            if (e is UnsupportedSecureTraversalException) {
                throw ResponseStatusException(
                    HttpStatus.INTERNAL_SERVER_ERROR,
                    "Backup cannot be created safely on this filesystem. Use a filesystem with secure directory access and try again.$liveWorldNotice"
                )
            }
            if (e is BackupPublicationFailedException) {
                throw ResponseStatusException(
                    HttpStatus.INTERNAL_SERVER_ERROR,
                    "The backup was written completely but could not be published under its final name. " +
                        "No existing backups were changed. Check the write permissions of the backups directory and try again.$liveWorldNotice"
                )
            }
            throw ResponseStatusException(
                HttpStatus.INTERNAL_SERVER_ERROR,
                "Backup failed. Check the instance files and try again.$liveWorldNotice"
            )
        } finally {
            runCatching { secureBackupDirectory?.close() }
            if (coordinatingLiveWorld) {
                // Restoring save-on belongs to the coordination contract, not to
                // the backup outcome: the server may have received the earlier
                // save-off even when its confirmation did not arrive, so every
                // failure and abort path must re-enable automatic saving.
                processManagerService.sendCommand(instanceId, SAVE_ON_COMMAND)
            }
        }

        return BackupEntry(
            name = backupName,
            size = backupAttributes!!.size(),
            timestamp = backupAttributes!!.lastModifiedTime().toMillis()
        )
    }

    /**
     * Sends a console command to the running game server and waits until the
     * server has confirmed its completion through the console output. The
     * confirmation must appear after the echo of this request's command, so a
     * matching older line in the console buffer cannot complete the wait.
     *
     * The echo is appended synchronously while the command is written to the
     * server's stdin; the response lines are captured asynchronously by the
     * console reader, so the wait polls a snapshot of the console buffer until
     * the deadline. Interruption of the waiting request thread is handled like
     * a timeout: the backup aborts before any archive is written, and the
     * caller restores automatic saving via save-on regardless of the outcome,
     * because a save-off may have reached the server even when its
     * confirmation did not.
     */
    private fun awaitConsoleConfirmation(instanceId: UUID, command: String, confirmation: String) {
        processManagerService.sendCommand(instanceId, command)
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(worldSaveConfirmationTimeoutMillis)
        while (true) {
            val lines = processManagerService.getLogSnapshot(instanceId)
            val echoIndex = lines.lastIndexOf(CONSOLE_ECHO_PREFIX + command)
            if (echoIndex >= 0 && lines.subList(echoIndex + 1, lines.size).any { it.contains(confirmation) }) {
                return
            }
            val remainingMillis = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
            if (remainingMillis <= 0) throw WorldSaveConfirmationTimeoutException(command)
            try {
                Thread.sleep(minOf(CONFIRMATION_POLL_MILLIS, remainingMillis))
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                throw WorldSaveConfirmationTimeoutException(command)
            }
        }
    }

    /**
     * Publishes the fully written temporary archive under its final name.
     *
     * Both names are generated by this service and contain no user input. The
     * move stays within the backups directory, so [StandardCopyOption.ATOMIC_MOVE]
     * is a rename within one directory and cannot fall back to copying: the
     * archive is either published completely or not at all, and if the
     * filesystem cannot provide that, the backup fails with a guided message
     * instead of publishing partially. A rename replaces a file or symbolic
     * link at the destination without following it, so no content is written
     * outside the backups directory. The POSIX and Windows implementations both
     * replace an existing target file during an atomic rename, which keeps the
     * previous behavior for two backups requested within the same second; a
     * provider that refuses to replace fails the backup with a guided message
     * and leaves the previous archive intact. [StandardCopyOption.REPLACE_EXISTING]
     * documents that intent and also governs the non-atomic fallback that
     * [StandardCopyOption.ATOMIC_MOVE] forbids. On failure the caller cleans up
     * the temporary file and existing backups remain untouched.
     */
    private fun publishBackupFile(temporaryFile: Path, finalFile: Path) {
        try {
            Files.move(
                temporaryFile,
                finalFile,
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE
            )
        } catch (e: IOException) {
            throw BackupPublicationFailedException()
        }
    }

    fun deleteBackup(instanceId: UUID, name: String) {
        instanceBackupOperationLocks.withLock(instanceId) { performDeleteBackup(instanceId, name) }
    }

    private fun performDeleteBackup(instanceId: UUID, name: String) {
        val backupDir = getBackupDir(instanceId)
        val file = backupDir.resolve(name)
        if (Files.exists(file)) {
            Files.delete(file)
        }
    }

    // ------------------------------------------------------------------
    // Restore
    //
    // A backup archives the complete instance directory except the backups
    // directory. The restore is the mirror image: it adopts the complete
    // archived set, so every archived top-level entry replaces its target and
    // every pre-existing top-level entry (except the backups directory and the
    // restore's own working entries) that the archive does not carry is
    // removed. Content is restored as stored; ownership and permissions are
    // not captured by the archive format and are therefore not restored.
    //
    // The restore never runs against a live game server: the process guard
    // below blocks the operation while the instance is running, starting,
    // being deleted, or already being restored, and the process manager's
    // restore reservation rejects concurrent starts and deletions for as long
    // as the restore holds it. A backup of a running instance stays possible
    // through its confirmed save-off/save-all coordination; the restore has no
    // such confirmation protocol, and world saving during the adoption cannot
    // be verified, so an active server is not stopped automatically either —
    // the user stops the instance (an orderly, asynchronous stop) and retries.
    // ------------------------------------------------------------------

    /**
     * Test seam: invoked immediately before each archived top-level entry is
     * renamed into the instance directory, after the replaced data has been
     * moved aside. Null in production use; tests use it to observe or obstruct
     * a specific publication step of the adoption.
     */
    internal var onBeforePublishRestoreEntry: ((entryName: String) -> Unit)? = null

    fun restoreBackup(instanceId: UUID, name: String) {
        instanceBackupOperationLocks.withLock(instanceId) { performGuardedRestore(instanceId, name) }
    }

    /**
     * Guards the restore against a live game server and holds the process
     * manager's restore reservation for the whole operation. The reservation
     * is taken under the per-instance backup operation lock, so it spans
     * exactly one restore attempt, and it is released in every path — a failed
     * restore leaves the instance startable again.
     *
     * Blocking instead of stopping the server is deliberate: the normal stop
     * is asynchronous, world saving cannot be confirmed while the adoption
     * rewrites the world data, and a failing stop must not silently become a
     * force-kill. The guided 409 leaves the decision to the user and states
     * that nothing was changed.
     */
    private fun performGuardedRestore(instanceId: UUID, name: String) {
        if (!processManagerService.beginRestore(instanceId)) {
            logger.warn("Restore of instance $instanceId blocked; the instance is running, starting, or being deleted")
            throw ResponseStatusException(
                HttpStatus.CONFLICT,
                "The instance cannot be restored while its game server is running or starting, while the " +
                    "instance is being deleted, or while another restore is already in progress. Stop the " +
                    "instance in the console and wait until its status reports STOPPED, then retry the " +
                    "restore. No instance data was changed."
            )
        }
        try {
            performRestore(instanceId, name)
        } finally {
            processManagerService.endRestore(instanceId)
        }
    }

    /**
     * Restores the named backup into the instance. The archive is validated
     * completely before anything is unpacked, unpacked into a fresh staging
     * directory inside the instance directory, and only then adopted by
     * renames within the instance directory. The replaced data is first moved
     * aside and deleted only after the whole archived set is in place; every
     * failure moves the previous data back, so the instance is either fully
     * restored or completely unchanged. The staging directory never survives
     * a restore attempt.
     */
    private fun performRestore(instanceId: UUID, name: String) {
        val instanceDir = instanceService.getInstancePath(instanceId)
        val backupDir = instanceDir.resolve(BACKUPS_DIRECTORY_NAME)
        logger.info("Instance $instanceId is being restored from a published backup")
        val stagingDir = instanceDir.resolve("$RESTORE_STAGING_PREFIX${UUID.randomUUID()}")
        try {
            val archiveName = validateBackupName(backupDir, name)
            openSecureInstanceDirectory(instanceDir).use { secureInstanceDirectory ->
                val secureBackups = try {
                    openSecureChildDirectory(secureInstanceDirectory, backupDir.fileName)
                } catch (_: NoSuchFileException) {
                    throw BackupArchiveNotFoundException()
                }
                secureBackups.use { backups ->
                    checkArchiveIsUsable(backups, archiveName)
                    validateArchive(instanceId, backups, archiveName)
                    extractArchive(backups, archiveName, stagingDir)
                }
            }
            adoptStagedRestore(instanceDir, stagingDir)
            logger.info("Restore of instance $instanceId completed")
        } catch (e: Exception) {
            // The guided HTTP reason never carries exception details, so the
            // log keeps the diagnosable anchor itself: the exception class
            // and whether the failure happened before or during the adoption.
            // Raw exception messages can contain instance paths or
            // archive-controlled entry names and never reach the log.
            logger.error("Restore failed: ${e.javaClass.simpleName} (${restoreFailurePhase(e)})")
            throw mapRestoreFailure(e)
        } finally {
            runCatching {
                if (Files.exists(stagingDir, LinkOption.NOFOLLOW_LINKS)) deleteTree(stagingDir)
            }
        }
    }

    /**
     * Restores only accept names as they are reported by [listBackups]: a
     * single path component without separators, parent-directory components or
     * other path syntax, so a crafted name can never address files outside the
     * backups directory.
     */
    private fun validateBackupName(backupDir: Path, name: String): Path {
        val invalid = name.isBlank() ||
            name == "." ||
            name == ".." ||
            name.contains('/') ||
            name.contains('\\') ||
            name.contains('\u0000')
        if (invalid) throw InvalidBackupNameException()
        val archiveName = backupDir.fileSystem.getPath(name)
        if (archiveName.nameCount != 1 || archiveName.fileName.toString() != name) {
            throw InvalidBackupNameException()
        }
        return archiveName
    }

    private fun checkArchiveIsUsable(backups: SecureDirectoryStream<Path>, archiveName: Path) {
        val attributes = try {
            readAttributes(backups, archiveName)
        } catch (_: NoSuchFileException) {
            throw BackupArchiveNotFoundException()
        }
        if (attributes.isSymbolicLink || !attributes.isRegularFile) throw BackupArchiveNotUsableException()
    }

    /**
     * Validates the complete archive before anything is unpacked, following
     * the same order of gates as the installer bundle validation in
     * `scripts/download.sh`: every entry name must be a relative
     * instance-directory path without parent components, unsupported
     * separators or a target inside the protected backups directory, entries
     * must not conflict, and the archive must carry the instance description
     * of exactly this instance. Violations abort the restore before the
     * staging directory is filled, so the existing instance data is untouched
     * in every rejection path. Entry names are never echoed into errors
     * because they are archive-controlled data.
     *
     * Symbolic links cannot escape from a restored archive: the zip reader
     * reads every entry as plain bytes and the extraction creates only
     * regular files and directories, so an entry that declares link semantics
     * materializes as a regular file whose content is the stored target text.
     */
    private fun validateArchive(instanceId: UUID, backups: SecureDirectoryStream<Path>, archiveName: Path) {
        ZipInputStream(BufferedInputStream(Channels.newInputStream(openArchiveChannel(backups, archiveName))))
            .use { zip ->
            val seenNames = HashSet<String>()
            var describedInstanceId: UUID? = null
            while (true) {
                val entry = try {
                    zip.nextEntry ?: break
                } catch (_: IOException) {
                    throw UnreadableBackupArchiveException()
                }
                validateArchiveEntryName(entry.name)
                val normalized = normalizedArchiveEntryName(entry.name)
                if (normalized != null && !seenNames.add(normalized)) throw BackupArchiveConflictException()
                if (!entry.isDirectory && normalized == INSTANCE_DESCRIPTION_ENTRY) {
                    describedInstanceId = readArchivedInstanceId(zip)
                }
            }
            if (describedInstanceId == null) throw IncompleteBackupArchiveException()
            if (describedInstanceId != instanceId) throw BackupInstanceMismatchException()
        }
    }

    /**
     * Second pass over the validated archive: extracts every entry into the
     * fresh staging directory. Every entry name is validated again while
     * streaming and every write targets the staging directory with
     * CREATE_NEW and NOFOLLOW_LINKS, so nothing is created outside the
     * staging directory and a partially extracted staging directory never
     * reaches the instance data.
     */
    private fun extractArchive(backups: SecureDirectoryStream<Path>, archiveName: Path, stagingDir: Path) {
        Files.createDirectory(stagingDir)
        ZipInputStream(BufferedInputStream(Channels.newInputStream(openArchiveChannel(backups, archiveName))))
            .use { zip ->
            while (true) {
                val entry = try {
                    zip.nextEntry ?: break
                } catch (_: IOException) {
                    throw UnreadableBackupArchiveException()
                }
                validateArchiveEntryName(entry.name)
                val components = normalizedComponents(entry.name)
                if (components.isEmpty()) continue
                if (entry.isDirectory) {
                    ensureStagingDirectory(stagingDir, components)
                } else {
                    ensureStagingDirectory(stagingDir, components.dropLast(1))
                    var target = stagingDir
                    for (component in components) target = target.resolve(component)
                    val output = try {
                        Files.newByteChannel(
                            target,
                            setOf<OpenOption>(
                                StandardOpenOption.CREATE_NEW,
                                StandardOpenOption.WRITE,
                                LinkOption.NOFOLLOW_LINKS
                            )
                        )
                    } catch (_: FileAlreadyExistsException) {
                        throw BackupArchiveConflictException()
                    }
                    output.use { channel -> zip.copyTo(Channels.newOutputStream(channel)) }
                }
            }
        }
    }

    private fun openArchiveChannel(backups: SecureDirectoryStream<Path>, archiveName: Path) =
        backups.newByteChannel(
            archiveName,
            setOf<OpenOption>(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)
        )

    /**
     * Validates one archive-controlled entry name with the same categories as
     * the installer bundle validation: absolute paths, drive-letter prefixes,
     * parent-directory components (as whole components, so a component that
     * merely contains ".." stays allowed), unsupported separator characters
     * and targets inside the protected backups directory are rejected.
     */
    private fun validateArchiveEntryName(entryName: String) {
        val reason = when {
            entryName.isEmpty() -> "it contains an entry with an empty name."
            '\u0000' in entryName -> "it contains an entry with an unsupported character."
            '\\' in entryName -> "it contains an entry that uses an unsupported path separator character."
            entryName.startsWith("/") || ARCHIVE_DRIVE_PREFIX.containsMatchIn(entryName) ->
                "it contains an entry with an absolute path."
            entryName.split('/').any { it == ".." } ->
                "it contains an entry that leaves the instance directory (parent-directory path component)."
            else -> null
        }
        if (reason != null) throw UnsafeArchiveEntryException(reason)
        if (normalizedComponents(entryName).firstOrNull() == BACKUPS_DIRECTORY_NAME) {
            throw UnsafeArchiveEntryException("it contains an entry that targets the protected backups directory.")
        }
    }

    private fun normalizedArchiveEntryName(entryName: String): String? {
        val components = normalizedComponents(entryName)
        return if (components.isEmpty()) null else components.joinToString("/")
    }

    private fun normalizedComponents(entryName: String): List<String> =
        entryName.split('/').filter { it.isNotEmpty() && it != "." }

    /**
     * Reads the archived instance description and returns its instance id.
     * The description is bounded and strictly parsed; an unreadable,
     * oversized or id-less description means the archive is not a complete
     * Moddex instance backup.
     */
    private fun readArchivedInstanceId(zip: ZipInputStream): UUID {
        val bytes = zip.readNBytes(INSTANCE_DESCRIPTION_MAX_BYTES)
        val exceedsLimit = zip.read() != -1
        zip.closeEntry()
        if (exceedsLimit) throw IncompleteBackupArchiveException()
        val description = try {
            objectMapper.readValue(bytes, Instance::class.java)
        } catch (_: Exception) {
            throw IncompleteBackupArchiveException()
        }
        return description.id ?: throw IncompleteBackupArchiveException()
    }

    /**
     * Creates the missing directories of a validated relative entry path
     * inside the staging directory. Components are checked with NOFOLLOW
     * attributes before reuse, so a directory can never be entered through a
     * link, and a file at a directory position is a conflicting archive.
     */
    private fun ensureStagingDirectory(stagingDir: Path, components: List<String>) {
        var current = stagingDir
        for (component in components) {
            current = current.resolve(component)
            val attributes = try {
                Files.readAttributes(current, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
            } catch (_: NoSuchFileException) {
                null
            }
            if (attributes == null) {
                Files.createDirectory(current)
            } else if (attributes.isSymbolicLink || !attributes.isDirectory) {
                throw BackupArchiveConflictException()
            }
        }
    }

    /**
     * Adopts the staged archived set by renames within the instance
     * directory. The replaced data is moved aside first and is deleted only
     * after every archived entry is in place; on any failure the published
     * entries move back into staging and the aside entries move back to their
     * original names, so the restore is either fully applied or the previous
     * state is completely restored. If a rollback cannot complete, the error
     * says so instead of claiming a clean previous state.
     */
    private fun adoptStagedRestore(instanceDir: Path, stagingDir: Path) {
        val stagingName = stagingDir.fileName.toString()
        val asides = ArrayList<Pair<Path, Path>>() // aside path -> original target
        val published = ArrayList<Pair<Path, Path>>() // published target -> staging origin
        try {
            val existingNames = Files.list(instanceDir).use { entries ->
                entries.map { it.fileName.toString() }.toList()
            }
            for (entryName in existingNames) {
                if (entryName == BACKUPS_DIRECTORY_NAME || entryName == stagingName) continue
                val aside = instanceDir.resolve("$RESTORE_ASIDE_PREFIX${UUID.randomUUID()}")
                try {
                    Files.move(instanceDir.resolve(entryName), aside, StandardCopyOption.ATOMIC_MOVE)
                } catch (_: NoSuchFileException) {
                    // Removed concurrently; nothing remains to move aside.
                    continue
                }
                asides.add(aside to instanceDir.resolve(entryName))
            }
            val stagedNames = Files.list(stagingDir).use { entries ->
                entries.map { it.fileName.toString() }.toList()
            }
            for (entryName in stagedNames) {
                onBeforePublishRestoreEntry?.invoke(entryName)
                val target = instanceDir.resolve(entryName)
                try {
                    Files.move(
                        stagingDir.resolve(entryName),
                        target,
                        StandardCopyOption.REPLACE_EXISTING,
                        StandardCopyOption.ATOMIC_MOVE
                    )
                } catch (_: IOException) {
                    throw RestoreAdoptionFailedException(rollbackComplete = false)
                }
                published.add(target to stagingDir.resolve(entryName))
            }
            var cleanupComplete = true
            for ((aside, _) in asides) {
                if (deleteTree(aside).isNotEmpty()) cleanupComplete = false
            }
            if (deleteTree(stagingDir).isNotEmpty()) cleanupComplete = false
            if (!cleanupComplete) throw RestoreCleanupFailedException()
        } catch (_: Exception) {
            throw RestoreAdoptionFailedException(rollbackAdoption(asides, published))
        }
    }

    /**
     * Moves published entries back into staging and the aside entries back to
     * their original names. Returns whether every entry could be restored;
     * entries that could not stay in place and make the rollback incomplete.
     */
    private fun rollbackAdoption(
        asides: List<Pair<Path, Path>>,
        published: List<Pair<Path, Path>>
    ): Boolean {
        var complete = true
        for ((target, origin) in published) {
            try {
                Files.move(target, origin, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: Exception) {
                complete = false
                // The entry holds only freshly restored archive data; freeing
                // its target name lets the original data move back.
                runCatching { deleteTree(target) }
            }
        }
        for ((aside, original) in asides) {
            try {
                Files.move(aside, original, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: Exception) {
                complete = false
            }
        }
        return complete
    }

    /**
     * Deletes a directory tree and returns every entry that could not be
     * removed, so partial failures stay visible instead of silently reporting
     * success. Entries that no longer exist are not counted. Symbolic links
     * are removed as links and never followed.
     */
    private fun deleteTree(root: Path): List<Path> {
        val failures = mutableListOf<Path>()
        fun deleteOrRecord(path: Path): FileVisitResult = try {
            Files.delete(path)
            FileVisitResult.CONTINUE
        } catch (_: NoSuchFileException) {
            FileVisitResult.CONTINUE
        } catch (_: IOException) {
            failures.add(path)
            FileVisitResult.CONTINUE
        }
        Files.walkFileTree(
            root,
            object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attributes: BasicFileAttributes): FileVisitResult =
                    deleteOrRecord(file)

                override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult {
                    if (exc !is NoSuchFileException) failures.add(file)
                    return FileVisitResult.CONTINUE
                }

                override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult =
                    if (exc != null) {
                        failures.add(dir)
                        FileVisitResult.CONTINUE
                    } else {
                        deleteOrRecord(dir)
                    }
            },
        )
        return failures
    }

    /**
     * Compact, secrets-free phase marker for the restore failure log line:
     * raw exception messages can contain instance paths or archive-controlled
     * entry names, so only the exception class and the phase reach the log.
     */
    private fun restoreFailurePhase(e: Exception): String = when (e) {
        is RestoreAdoptionFailedException -> "during the adoption of the staged data"
        else -> "before the instance data was touched"
    }

    /**
     * Maps restore failures to guided HTTP errors. Every message names the
     * current state and a safe next action; archive-controlled entry names,
     * instance paths and exception details are never included.
     */
    private fun mapRestoreFailure(e: Exception): ResponseStatusException = when (e) {
        is ResponseStatusException -> e
        is InvalidBackupNameException -> ResponseStatusException(
            HttpStatus.BAD_REQUEST,
            "The backup name is invalid. Use a backup name exactly as it is shown in the instance's backup " +
                "list and try again."
        )
        is BackupArchiveNotFoundException -> ResponseStatusException(
            HttpStatus.NOT_FOUND,
            "No backup with this name exists for this instance. Refresh the backup list and try again."
        )
        is BackupArchiveNotUsableException -> ResponseStatusException(
            HttpStatus.BAD_REQUEST,
            "The selected backup is not a usable archive file. Refresh the backup list and try again."
        )
        is UnsafeArchiveEntryException -> ResponseStatusException(
            HttpStatus.BAD_REQUEST,
            "The archive is not a safe instance backup: ${e.reason} The restore was rejected before anything " +
                "was changed. Remove this backup and restore a different one."
        )
        is BackupArchiveConflictException -> ResponseStatusException(
            HttpStatus.BAD_REQUEST,
            "The archive contains conflicting duplicate entries. The restore was rejected before anything " +
                "was changed. Remove this backup and restore a different one."
        )
        is IncompleteBackupArchiveException -> ResponseStatusException(
            HttpStatus.BAD_REQUEST,
            "The archive is not a complete instance backup. The restore was rejected before anything was " +
                "changed. Use a backup created by Moddex for this instance."
        )
        is BackupInstanceMismatchException -> ResponseStatusException(
            HttpStatus.BAD_REQUEST,
            "The archive belongs to a different instance. The restore was rejected before anything was " +
                "changed. Choose a backup that was created for this instance."
        )
        is UnreadableBackupArchiveException, is ZipException -> ResponseStatusException(
            HttpStatus.BAD_REQUEST,
            "The backup could not be read as an archive. The existing instance data was not changed. " +
                "Verify the backup and try again, or delete it and create a new backup."
        )
        is UnsupportedBackupSymbolicLinkException -> ResponseStatusException(
            HttpStatus.BAD_REQUEST,
            "Restore cannot be performed because a required directory is a symbolic link. Remove symbolic " +
                "links from the instance directory and try again."
        )
        is UnsupportedSecureTraversalException -> ResponseStatusException(
            HttpStatus.INTERNAL_SERVER_ERROR,
            "Restore cannot be performed safely on this filesystem. Use a filesystem with secure directory " +
                "access and try again."
        )
        is RestoreAdoptionFailedException ->
            if (e.rollbackComplete) {
                ResponseStatusException(
                    HttpStatus.INTERNAL_SERVER_ERROR,
                    "The restore failed while applying the archived data. The previous instance data was moved " +
                        "back to its original state and no partial changes remain. Check the instance directory " +
                        "and try again."
                )
            } else {
                ResponseStatusException(
                    HttpStatus.INTERNAL_SERVER_ERROR,
                    "The restore failed while applying the archived data and the previous instance data could " +
                        "not be fully restored. Some previous entries may remain in the instance directory " +
                        "under restore-aside names. Verify the instance directory before trying again."
                )
            }
        else -> ResponseStatusException(
            HttpStatus.INTERNAL_SERVER_ERROR,
            "The restore failed before any changes were applied and the existing instance data was not " +
                "changed. Check the instance files and try again."
        )
    }

    private fun openSecureInstanceDirectory(instanceDir: Path): SecureDirectoryStream<Path> {
        val absoluteInstanceDir = instanceDir.toAbsolutePath()
        val instanceName = absoluteInstanceDir.fileName ?: throw IOException("Instance path has no directory name")
        val parent = absoluteInstanceDir.parent ?: throw IOException("Instance path has no parent directory")
        val secureParent = openSecureDirectory(parent.toRealPath())
        return try {
            openSecureChildDirectory(secureParent, instanceName)
        } finally {
            secureParent.close()
        }
    }

    private fun openSecureDirectory(path: Path): SecureDirectoryStream<Path> {
        val root = path.root ?: throw IOException("Secure directory path must be absolute")
        val rootDirectory = Files.newDirectoryStream(root)
        var current = rootDirectory as? SecureDirectoryStream<Path>
            ?: run {
                rootDirectory.close()
                throw UnsupportedSecureTraversalException()
            }

        try {
            for (component in path) {
                val next = try {
                    current.newDirectoryStream(component, LinkOption.NOFOLLOW_LINKS)
                } catch (e: UnsupportedOperationException) {
                    throw UnsupportedSecureTraversalException()
                }
                val previous = current
                current = next
                previous.close()
            }
            return current
        } catch (e: Exception) {
            runCatching { current.close() }
            throw e
        }
    }

    private fun openSecureChildDirectory(
        parent: SecureDirectoryStream<Path>,
        name: Path
    ): SecureDirectoryStream<Path> {
        val attributes = readAttributes(parent, name)
        if (attributes.isSymbolicLink) throw UnsupportedBackupSymbolicLinkException()
        if (!attributes.isDirectory) throw IOException("Expected a directory")
        return try {
            parent.newDirectoryStream(name, LinkOption.NOFOLLOW_LINKS)
        } catch (e: UnsupportedOperationException) {
            throw UnsupportedSecureTraversalException()
        }
    }

    private fun addDirectoryToZip(
        directory: SecureDirectoryStream<Path>,
        relativeDirectory: Path,
        zos: ZipOutputStream
    ) {
        for (entry in directory) {
            val name = entry.fileName ?: throw IOException("Directory entry has no name")
            val attributes = readAttributes(directory, name)
            if (attributes.isSymbolicLink) throw UnsupportedBackupSymbolicLinkException()

            if (attributes.isDirectory) {
                if (name.toString() == "backups") continue
                directory.newDirectoryStream(name, LinkOption.NOFOLLOW_LINKS).use { child ->
                    addDirectoryToZip(child, relativeDirectory.resolve(name), zos)
                }
                continue
            }

            if (!attributes.isRegularFile) throw IOException("Unsupported instance file type")
            val relative = relativeDirectory.resolve(name).toString().replace("\\", "/")
            zos.putNextEntry(ZipEntry(relative))
            try {
                val channel = try {
                    directory.newByteChannel(
                        name,
                        setOf<OpenOption>(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)
                    )
                } catch (e: UnsupportedOperationException) {
                    throw UnsupportedSecureTraversalException()
                }
                Channels.newInputStream(channel).use { it.copyTo(zos) }
            } finally {
                zos.closeEntry()
            }
        }
    }

    private fun readAttributes(
        directory: SecureDirectoryStream<Path>,
        name: Path
    ): BasicFileAttributes =
        directory.getFileAttributeView(name, BasicFileAttributeView::class.java, LinkOption.NOFOLLOW_LINKS)
            ?.readAttributes()
            ?: throw IOException("File attributes are unavailable")

    private class UnsupportedBackupSymbolicLinkException : IOException()

    private class UnsupportedSecureTraversalException : IOException()

    private class BackupPublicationFailedException : IOException()

    private class InvalidBackupNameException : IOException()

    private class BackupArchiveNotFoundException : IOException()

    private class BackupArchiveNotUsableException : IOException()

    private class UnsafeArchiveEntryException(val reason: String) : IOException()

    private class BackupArchiveConflictException : IOException()

    private class IncompleteBackupArchiveException : IOException()

    private class BackupInstanceMismatchException : IOException()

    private class UnreadableBackupArchiveException : IOException()

    private class RestoreAdoptionFailedException(val rollbackComplete: Boolean) : IOException()

    private class RestoreCleanupFailedException : IOException()

    /** The running server did not confirm a save command before the deadline. */
    private class WorldSaveConfirmationTimeoutException(val command: String) : RuntimeException()

    private fun getBackupDir(instanceId: UUID): Path {
        return instanceService.getInstancePath(instanceId).resolve("backups")
    }
}

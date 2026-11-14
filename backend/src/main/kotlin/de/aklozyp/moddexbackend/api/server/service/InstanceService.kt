
package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.io.IOException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.FileOwnerAttributeView
import java.nio.file.attribute.PosixFileAttributeView
import java.time.Instant
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.stream.Stream
import kotlin.streams.asSequence

@Service
class InstanceService(
    private val serverSettingsService: ServerSettingsService,
    private val objectMapper: ObjectMapper,
    private val instanceInstallerService: InstanceInstallerService,
    private val modListStore: InstanceModListStore,
    private val logger: Logger,
    private val directories: ModdexDirectories,
) {
    private fun instancesRoot(): Path {
        val root = serverSettingsService.getServerSettings().projectPath?.takeIf { it.isNotBlank() }
            ?: directories.dataDir.toString()
        val base = Path.of(root).resolve("instances")
        Files.createDirectories(base)
        return base
    }

    fun getAllInstances(): List<Instance> {
        val root = instancesRoot()
        logger.info("Listing instances from ${root.toAbsolutePath()}")
        val instances = Files.list(root).use { stream ->
            stream.filter { Files.isDirectory(it) }
                .map { readInstanceConfig(it) }
                .filter { it != null }
                .map { it!! }
                .toList()
        }
        logger.info("Found ${instances.size} instance entries")
        return instances
    }

    fun getInstanceById(id: UUID): Instance {
        logger.info("Looking up instance with id=$id")
        val (_, inst) = findById(id) ?: run {
            logger.warn("Instance with id=$id not found")
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "Instance with id $id not found")
        }
        return inst
    }

    fun getInstancePath(id: UUID): Path {
        val (path, _) = findById(id) ?: run {
            logger.warn("Instance with id=$id not found")
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "Instance with id $id not found")
        }
        return path
    }

    fun createAndInstallInstance(instance: Instance): Instance {
        // The identity is chosen by the server: a client-supplied id is ignored,
        // so a duplicate or replayed request can neither adopt an existing
        // instance's identity nor overwrite its data.
        val id = generateInstanceId()
        val name = instance.name ?: "unnamed"
        instance.id = id

        val serverSettings = serverSettingsService.getServerSettings()
        if (instance.javaXmx.isNullOrBlank()) {
            instance.javaXmx = serverSettings.defaultJavaXmx ?: ServerSettingsService.DEFAULT_JAVA_XMX
        }
        if (instance.javaXms.isNullOrBlank()) {
            instance.javaXms = serverSettings.defaultJavaXms ?: ServerSettingsService.DEFAULT_JAVA_XMS
        }

        var reservedDir: Path? = null
        var phase = "directory reservation"
        try {
            val dir = reserveInstanceDirectory(name)
            reservedDir = dir
            logger.info("Registering instance id=$id name='$name' at ${dir.toAbsolutePath()}")
            phase = "instance metadata"
            modListStore.ensure(dir, id)
            writeInstanceConfig(dir, instance)
            phase = "download and installation"
            instanceInstallerService.downloadInstaller(instance, dir)
        } catch (e: Exception) {
            val diagnosisRecord = rollbackFailedCreation(reservedDir, id, name, phase, e)
            logger.error(
                "Failed to create instance id=$id during $phase. The incomplete creation was rolled back. " +
                    "Check the backend log and the saved diagnosis record, then retry the creation.",
            )
            throw translateCreationFailure(e, diagnosisRecord, reservedDir != null)
        }

        logger.info("Instance id=$id registered successfully")
        return instance
    }

    /**
     * Rolls a failed creation back, so no seemingly ready instance remains.
     *
     * The diagnosis record is written first, so the evidence of the failed job
     * survives even when the directory cleanup itself fails. The configuration
     * is removed before the rest of the tree: instance listing ignores
     * directories without a readable configuration, so even a partially
     * blocked cleanup can never leave a startable-looking instance behind.
     * Removing the tree also frees the reserved directory name, so the
     * creation can be retried with the same name.
     *
     * Rollback problems are logged with a safe next action; they never mask
     * the original creation failure. The instance was never registered and no
     * process was ever started for it, so no deletion gate applies here.
     */
    private fun rollbackFailedCreation(
        reservedDir: Path?,
        id: UUID,
        name: String,
        phase: String,
        failure: Exception,
    ): String? {
        val diagnosisRecord = writeCreationFailureRecord(id, name, phase, failure)
        if (reservedDir == null) return diagnosisRecord
        try {
            Files.deleteIfExists(reservedDir.resolve("instance.json"))
        } catch (_: Exception) {
            logger.warn(
                "Could not remove the configuration of the failed instance id=$id. " +
                    "Check the instance directory permissions; the following cleanup removes it if possible.",
            )
        }
        val remaining = try {
            deleteTree(reservedDir)
        } catch (_: Exception) {
            logger.warn(
                "Could not remove the directory of the failed instance id=$id. " +
                    "Check the instance directory permissions and remove the remaining directory manually.",
            )
            return diagnosisRecord
        }
        if (remaining.isNotEmpty()) {
            val relative = remaining.map { relativeRemaining(reservedDir, it) }
            logger.warn(
                "Rollback of instance id=$id could not remove ${relative.size} entries " +
                    "under ${reservedDir.toAbsolutePath()}: $relative. " +
                    "Check the instance directory permissions and remove them manually.",
            )
        }
        return diagnosisRecord
    }

    /**
     * Preserves the diagnosable job data of a failed creation separately from
     * the instances, under the backend logs directory. Only already-safe,
     * user-facing text is recorded: the guided HTTP reason when one exists,
     * otherwise just the exception kind. Raw exception messages never enter
     * the record. A failed record write is a warning, not a rollback failure.
     */
    private fun writeCreationFailureRecord(id: UUID, name: String, phase: String, failure: Exception): String? {
        return try {
            val failuresDir = directories.logsDir.resolve(CREATION_FAILURE_RECORDS_DIR)
            Files.createDirectories(failuresDir)
            val recordFile = failuresDir.resolve("${RECORD_FILE_TIMESTAMP.format(LocalDateTime.now())}-$id.json")
            val record = InstanceCreationFailureRecord(
                instanceId = id,
                instanceName = name,
                phase = phase,
                failedAt = Instant.now().toString(),
                errorKind = failure.javaClass.simpleName,
                detail = (failure as? ResponseStatusException)?.reason,
            )
            objectMapper.writerWithDefaultPrettyPrinter().writeValue(recordFile.toFile(), record)
            logger.info(
                "Saved a diagnosis record for the failed creation of instance id=$id at ${recordFile.toAbsolutePath()}",
            )
            recordFile.fileName.toString()
        } catch (_: Exception) {
            logger.warn(
                "Could not save a diagnosis record for the failed creation of instance id=$id. " +
                    "Check the logs directory permissions.",
            )
            null
        }
    }

    /**
     * Keeps the guided wording of the original failure and appends the
     * rollback outcome, so the caller learns that no half-created instance
     * remains and where the diagnosis record was preserved. Failures without
     * their own safe message (for example raw metadata-phase I/O errors)
     * become a guided internal error instead of a raw exception response.
     */
    private fun translateCreationFailure(
        failure: Exception,
        diagnosisRecord: String?,
        directoryReserved: Boolean,
    ): Exception {
        val rollbackOutcome = when {
            diagnosisRecord != null && directoryReserved ->
                " The incomplete instance directory was removed and a diagnosis record was saved as " +
                    "$CREATION_FAILURE_RECORDS_DIR/$diagnosisRecord in the backend logs directory."
            diagnosisRecord != null ->
                " No instance directory was reserved, so nothing else remains; a diagnosis record was saved as " +
                    "$CREATION_FAILURE_RECORDS_DIR/$diagnosisRecord in the backend logs directory."
            directoryReserved ->
                " The incomplete instance directory was removed; the backend log holds the failure details."
            else ->
                " No instance directory was reserved, so nothing else remains; the backend log holds the failure details."
        }
        if (failure is ResponseStatusException) {
            val reason = failure.reason?.takeIf { it.isNotBlank() }
                ?: "The instance creation failed and was rolled back."
            return ResponseStatusException(failure.statusCode, reason + rollbackOutcome)
        }
        return ResponseStatusException(
            HttpStatus.INTERNAL_SERVER_ERROR,
            "Could not create the instance." + rollbackOutcome + " Check the backend log for the failure details, then retry the creation.",
        )
    }

    fun updateInstanceById(id: UUID, instance: Instance): Instance {
        logger.info("Updating instance id=$id")
        val (dir, _) = findById(id) ?: run {
            logger.warn("Cannot update; instance with id=$id not found")
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "Instance with id $id not found")
        }
        instance.id = id
        writeInstanceConfig(dir, instance)
        logger.info("Instance id=$id updated")
        return instance
    }

    fun deleteInstanceById(id: UUID) {
        logger.info("Deleting instance id=$id")
        val (dir, _) = findById(id) ?: run {
            logger.warn("Cannot delete; instance with id=$id not found")
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "Instance with id $id not found")
        }
        val remaining = deleteTree(dir)
        if (remaining.isEmpty()) {
            logger.info("Instance id=$id deleted (path=${dir.toAbsolutePath()})")
            return
        }
        val relative = remaining.map { relativeRemaining(dir, it) }
        logger.warn(
            "Instance id=$id could not be fully deleted; ${relative.size} entries remain " +
                "under ${dir.toAbsolutePath()}: $relative",
        )
        throw InstanceDeletionException(relative, dir.fileName.toString())
    }

    private fun relativeRemaining(directory: Path, path: Path): String =
        directory.relativize(path).toString().replace('\\', '/').ifEmpty { "." }

    /**
     * Deletes the directory tree and returns every entry that could not be removed,
     * so partial failures stay visible instead of silently reporting success.
     * Entries that no longer exist are not counted (concurrent removal is success).
     * Symbolic links are removed as links and never followed.
     */
    private fun deleteTree(dir: Path): List<Path> {
        val failures = mutableListOf<Path>()
        Files.walkFileTree(
            dir,
            object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    try {
                        Files.delete(file)
                    } catch (_: NoSuchFileException) {
                        // Already gone; nothing remains for this entry.
                    } catch (_: IOException) {
                        failures.add(file)
                    }
                    return FileVisitResult.CONTINUE
                }

                override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult {
                    if (exc !is NoSuchFileException) {
                        failures.add(file)
                    }
                    return FileVisitResult.CONTINUE
                }

                override fun postVisitDirectory(dirPath: Path, exc: IOException?): FileVisitResult {
                    if (exc != null) {
                        // The directory contents could not be traversed completely;
                        // keep the directory itself as the visible remainder.
                        failures.add(dirPath)
                        return FileVisitResult.CONTINUE
                    }
                    try {
                        Files.delete(dirPath)
                    } catch (_: NoSuchFileException) {
                        // Already gone; nothing remains for this entry.
                    } catch (_: IOException) {
                        failures.add(dirPath)
                    }
                    return FileVisitResult.CONTINUE
                }
            },
        )
        return failures
    }

    private fun readInstanceConfig(dir: Path): Instance? {
        val file = dir.resolve("instance.json").toFile()
        return try {
            if (file.exists()) {
                val instance = objectMapper.readValue<Instance>(file)
                logger.debug("Loaded instance config from ${file.absolutePath} (id=${instance.id})")
                instance
            } else {
                null
            }
        } catch (_: Exception) {
            logger.warn("Could not read instance.json in ${dir.toAbsolutePath()}. Check the file and its permissions.")
            null
        }
    }

    private fun writeInstanceConfig(dir: Path, instance: Instance) {
        val target = dir.resolve("instance.json")
        try {
            writeJsonAtomically(target, objectMapper, instance, logger) { pendingFile ->
                replaceInstanceFile(pendingFile, target)
            }
            logger.info("Persisted instance config id=${instance.id} at ${dir.toAbsolutePath()}")
        } catch (_: Exception) {
            val guidance = "Could not save instance configuration. Check the instance directory, permissions, " +
                "file ownership, symbolic links, and atomic replacement support, then retry."
            logger.error(guidance)
            throw ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, guidance)
        }
    }

    internal fun replaceInstanceFile(pendingFile: Path, target: Path) {
        val attributes = try {
            Files.readAttributes(target, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        } catch (_: NoSuchFileException) {
            null
        }
        if (attributes?.isSymbolicLink == true) {
            throw IOException("Symbolic-link instance configurations cannot be replaced.")
        }
        if (attributes != null) {
            preserveInstanceFileAttributes(pendingFile, target)
        }
        // Never fall back to truncating the live configuration if atomic replacement is unavailable.
        Files.move(pendingFile, target, ATOMIC_MOVE, REPLACE_EXISTING)
    }

    internal fun preserveInstanceFileAttributes(pendingFile: Path, target: Path) {
        val targetView = Files.getFileAttributeView(target, PosixFileAttributeView::class.java, NOFOLLOW_LINKS)
        if (targetView != null) {
            val attributes = targetView.readAttributes()
            val pendingView = Files.getFileAttributeView(pendingFile, PosixFileAttributeView::class.java, NOFOLLOW_LINKS)
                ?: throw IOException("Pending instance configuration does not support POSIX attributes.")
            val pendingAttributes = pendingView.readAttributes()
            if (pendingAttributes.group() != attributes.group()) {
                pendingView.setGroup(attributes.group())
            }
            if (pendingAttributes.owner() != attributes.owner()) {
                pendingView.setOwner(attributes.owner())
            }
            // Ownership changes can clear permission bits, so apply the mode last.
            pendingView.setPermissions(attributes.permissions())
        } else {
            val owner = Files.getFileAttributeView(target, FileOwnerAttributeView::class.java, NOFOLLOW_LINKS)?.owner
            if (owner != null && Files.getOwner(pendingFile, NOFOLLOW_LINKS) != owner) {
                Files.setOwner(pendingFile, owner)
            }
        }
    }

    /**
     * Draws a fresh server-side id and enforces uniqueness against the ids
     * already persisted under the instances root, so no duplicate id is minted
     * even when a damaged or hand-copied directory already uses one.
     */
    private fun generateInstanceId(): UUID {
        val existingIds = existingInstanceIds()
        var candidate = UUID.randomUUID()
        while (existingIds.contains(candidate)) {
            candidate = UUID.randomUUID()
        }
        return candidate
    }

    private fun existingInstanceIds(): Set<UUID> {
        val root = instancesRoot()
        return Files.list(root).use { stream ->
            stream.asSequence()
                .filter { Files.isDirectory(it) }
                .mapNotNull { readInstanceConfig(it)?.id }
                .toSet()
        }
    }

    /**
     * Creates and thereby reserves the instance directory. The atomic create is
     * the reservation: concurrent creations with the same name never share a
     * directory, because the loser of the race retries with the next suffix.
     * Any name occupied by a file, directory, or symlink (including dangling
     * ones) blocks that candidate; only the name-collision error is retried.
     */
    private fun reserveInstanceDirectory(name: String): Path {
        val root = instancesRoot()
        val sanitized = name.replace(Regex("[^a-zA-Z0-9.-]"), "_")
        var candidate = root.resolve(sanitized)
        var counter = 1
        while (true) {
            try {
                Files.createDirectory(candidate)
                return candidate
            } catch (_: FileAlreadyExistsException) {
                candidate = root.resolve("$sanitized ($counter)")
                counter++
            }
        }
    }

    private fun findById(id: UUID): Pair<Path, Instance>? {
        val root = instancesRoot()
        return Files.list(root).use { stream: Stream<Path> ->
            stream.asSequence()
                .filter { Files.isDirectory(it) }
                .mapNotNull { dir ->
                    readInstanceConfig(dir)?.let { inst ->
                        if (inst.id == id) dir to inst else null
                    }
                }
                .firstOrNull()
        }
    }

    companion object {
        const val CREATION_FAILURE_RECORDS_DIR = "instance-creation-failures"

        /**
         * Record file names must stay portable across platforms; colons are
         * avoided even though they would be valid on POSIX.
         */
        private val RECORD_FILE_TIMESTAMP = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")
    }
}

/**
 * One diagnosis record of a failed instance creation, preserved separately
 * from the instances under the backend logs directory. `detail` carries only
 * already-safe, user-facing text (the guided HTTP reason when available);
 * raw exception messages are never stored.
 */
data class InstanceCreationFailureRecord(
    val instanceId: UUID,
    val instanceName: String,
    val phase: String,
    val failedAt: String,
    val errorKind: String,
    val detail: String?,
)

package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.services.Logger
import jakarta.annotation.PreDestroy
import org.springframework.beans.factory.annotation.Value
import org.springframework.context.event.ContextClosedEvent
import org.springframework.context.event.EventListener
import org.springframework.stereotype.Service
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

@Service
class ProcessManagerService(
    private val instanceService: InstanceService,
    private val eulaService: EulaService,
    private val logger: Logger,
    private val processLauncher: ServerProcessLauncher,
    @Value("\${moddex.process.shutdown-timeout-ms:60000}")
    private val shutdownTimeoutMillis: Long = 60_000,
    private val startManifestStore: InstanceStartManifestStore,
) {
    private class ManagedProcess {
        val launched = CompletableFuture<Process?>()
        val commandLock = Any()
        val shutdownStop = AtomicReference<CompletableFuture<Unit>?>()
        val children = ConcurrentHashMap<Long, ProcessHandle>()
        val childInspectionFailed = AtomicBoolean(false)
        var shutdownMember = false
        @Volatile var process: Process? = null
    }

    private val processes = ConcurrentHashMap<UUID, ManagedProcess>()
    private val deletionsInProgress: MutableSet<UUID> = ConcurrentHashMap.newKeySet()
    private val restoresInProgress: MutableSet<UUID> = ConcurrentHashMap.newKeySet()
    private val logs = ConcurrentHashMap<UUID, MutableList<String>>()
    private val MAX_LOG_LINES = 2000
    private val lifecycleLock = Any()
    @Volatile private var shuttingDown = false
    private var shutdownCompleted = false
    private var shutdownFailure: String? = null

    init {
        require(shutdownTimeoutMillis > 0) { "Game-server shutdown timeout must be greater than zero" }
    }

    fun startInstance(id: UUID) {
        val managed = synchronized(lifecycleLock) {
            checkAcceptingStarts()
            check(id !in deletionsInProgress) {
                "Instance is currently being deleted; wait for the deletion to finish before starting it."
            }
            check(id !in restoresInProgress) {
                "Instance is currently being restored from a backup; wait for the restore to finish before " +
                    "starting it, so no game server writes into world data that the restore is replacing."
            }
            val existing = processes[id]
            check(existing?.childInspectionFailed?.get() != true) {
                "Old game-server termination could not be verified. $RECOVERY_ACTION"
            }
            check(existing == null || (existing.launched.isDone && existing.process?.isAlive != true &&
                existing.children.values.none { it.isAlive })) {
                "Instance is already running or starting"
            }
            ManagedProcess().also { processes[id] = it }
        }

        try {
            if (!eulaService.isEulaAccepted(id)) {
                throw EulaNotAcceptedException()
            }
            val instance = instanceService.getInstanceById(id)
            val directory = instanceService.getInstancePath(id)
            val command = buildStartCommand(instance, directory)
            synchronized(lifecycleLock) { checkAcceptingStarts() }
            logger.info("Starting instance $id with command: ${command.joinToString(" ")}")

            // The registered launch also belongs to shutdown while the native spawn is in flight.
            val process = processLauncher.start(command, directory)
            synchronized(lifecycleLock) {
                managed.process = process
                logs[id] = mutableListOf()
                if (shuttingDown) managed.shutdownMember = true
                managed.launched.complete(process)
            }

            thread(name = "Instance-Log-$id", isDaemon = true) {
                try {
                    BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                        reader.forEachLine { line -> appendLog(id, line) }
                    }
                } catch (e: Exception) {
                    logger.error("Error reading logs for instance $id. Check the instance log files.")
                } finally {
                    logger.info("Instance $id console stream closed")
                }
            }
        } finally {
            val process = managed.process
            if (process == null) {
                managed.launched.complete(null)
                processes.remove(id, managed)
            } else if (shuttingDown) {
                // A late spawn must still receive stop, even if shutdown already reported a timeout.
                requestShutdownStop(id, managed, process)
            }
        }
    }

    fun stopInstance(id: UUID) {
        processes[id]?.let { managed -> managed.process?.let { observeChildren(managed, it) } }
        sendCommand(id, "stop")
    }

    fun killInstance(id: UUID) {
        val process = processes[id]?.process
        if (process != null && process.isAlive) {
            process.destroyForcibly()
        }
    }

    fun sendCommand(id: UUID, command: String) {
        val managed = processes[id] ?: return
        val process = managed.process
        if (process != null && process.isAlive) {
            try {
                writeCommand(id, managed, process, command)
            } catch (e: Exception) {
                logger.error("Failed to send command to instance $id. $RECOVERY_ACTION")
            }
        }
    }

    fun getLogs(id: UUID): List<String> {
        return logs[id] ?: emptyList()
    }

    /**
     * Returns a consistent copy of the instance's current console lines,
     * including the echoed commands and the captured server output so far.
     * The copy is taken under the same synchronization as the appends, so a
     * reader can scan the lines while the console reader thread keeps
     * appending without exposing the live buffer.
     */
    fun getLogSnapshot(id: UUID): List<String> {
        val logList = logs[id] ?: return emptyList()
        synchronized(logList) { return logList.toList() }
    }

    fun getStatus(id: UUID): String {
        val proc = processes[id]?.process ?: return "STOPPED"
        return if (proc.isAlive) "RUNNING" else "STOPPED"
    }

    /**
     * Reports whether the instance currently has a live game-server process.
     */
    fun isInstanceRunning(id: UUID): Boolean = getStatus(id) == "RUNNING"

    /**
     * Registers an in-progress instance deletion and reports whether the
     * instance is currently safe to delete. The decision is atomic with the
     * start gate: while the reservation is held, [startInstance] rejects the
     * instance, so a concurrent start cannot spawn a game server into a
     * directory that is about to be removed.
     *
     * Returns false — without taking the reservation — when a game-server
     * process is alive, a launch is still in flight, child-process termination
     * could not be verified, a deletion reservation is already held, or a
     * restore of the same instance is in progress. The caller must then leave
     * all instance data untouched. Before deciding, the child-process snapshot
     * of a registered process is refreshed, so even a descendant that appeared
     * without any stop command blocks the deletion. The same conditions that
     * let [startInstance] accept a (re)start are the ones that make the
     * instance safe to delete, so the deletion gate is never weaker than the
     * start gate.
     */
    fun beginDeletion(id: UUID): Boolean = synchronized(lifecycleLock) {
        val existing = processes[id]
        if (existing != null) {
            // Refresh the child snapshot first, so a descendant that appeared
            // without any stop command is still seen before deleting.
            existing.process?.let { observeChildren(existing, it) }
        }
        val processActive = existing != null &&
            (
                !existing.launched.isDone || existing.process?.isAlive == true ||
                    existing.children.values.any { it.isAlive } ||
                    existing.childInspectionFailed.get()
                )
        if (processActive || id in restoresInProgress) {
            false
        } else {
            deletionsInProgress.add(id)
        }
    }

    /**
     * Releases the deletion reservation taken by [beginDeletion], so starts
     * are permitted again (subject to the usual running checks). Safe to call
     * even when no reservation is held, for example after a failed deletion.
     */
    fun endDeletion(id: UUID) {
        deletionsInProgress.remove(id)
    }

    /**
     * Registers an in-progress backup restore and reports whether the instance
     * is currently safe to restore. The decision is atomic with the start gate:
     * while the reservation is held, [startInstance] rejects the instance, so
     * a concurrent start cannot spawn a game server into world data that the
     * restore is replacing, and the restore itself refuses a running game
     * server that could concurrently write into the paths it rewrites.
     *
     * Returns false — without taking the reservation — when a game-server
     * process is alive, a launch is still in flight, child-process termination
     * could not be verified, a deletion reservation is already held (the
     * deletion removes the data the restore would rebuild), or a restore
     * reservation is already held. The caller must then leave all instance
     * data untouched. Before deciding, the child-process snapshot of a
     * registered process is refreshed and the process-active conditions are
     * evaluated exactly like [beginDeletion], so the restore gate is never
     * weaker than the start gate. Unlike deletion, a restore does not remove
     * the instance, so an instance without any registered process is safe to
     * restore.
     *
     * The reservation does not consider the shutdown state: it mirrors the
     * deletion gate, and a running game server already blocks the restore
     * during shutdown, while restoring a stopped instance touches only files
     * and cannot conflict with the shutdown coordination.
     */
    fun beginRestore(id: UUID): Boolean = synchronized(lifecycleLock) {
        val existing = processes[id]
        if (existing != null) {
            // Refresh the child snapshot first, so a descendant that appeared
            // without any stop command is still seen before the restore.
            existing.process?.let { observeChildren(existing, it) }
        }
        val processActive = existing != null &&
            (
                !existing.launched.isDone || existing.process?.isAlive == true ||
                    existing.children.values.any { it.isAlive } ||
                    existing.childInspectionFailed.get()
                )
        if (processActive || id in deletionsInProgress || id in restoresInProgress) {
            false
        } else {
            restoresInProgress.add(id)
        }
    }

    /**
     * Releases the restore reservation taken by [beginRestore], so starts and
     * deletions are permitted again (subject to the usual checks). Safe to
     * call even when no reservation is held, for example after a failed
     * restore.
     */
    fun endRestore(id: UUID) {
        restoresInProgress.remove(id)
    }

    @EventListener(ContextClosedEvent::class)
    fun rejectStartsOnContextClose() {
        synchronized(lifecycleLock) {
            shuttingDown = true
            processes.values.forEach { managed ->
                if (requiresShutdownVerification(managed)) managed.shutdownMember = true
            }
        }
    }

    @PreDestroy
    @Synchronized
    fun shutdown() {
        if (shutdownCompleted) {
            shutdownFailure?.let { throw IllegalStateException(it) }
            return
        }

        val snapshot = synchronized(lifecycleLock) {
            shuttingDown = true
            processes.filterValues(::requiresShutdownVerification)
        }
        val failures = mutableListOf<String>()
        var interrupted = false
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(shutdownTimeoutMillis)
        val executor = Executors.newCachedThreadPool { task ->
            Thread(task, "Instance-Shutdown").apply { isDaemon = true }
        }

        try {
            val stops = snapshot.mapValues { (id, managed) ->
                executor.submit(Callable { stopForShutdown(id, managed, deadline) })
            }
            for ((id, stop) in stops) {
                if (interrupted) {
                    failures.add("$id: termination not confirmed after interruption")
                    continue
                }
                try {
                    stop.get(remainingNanos(deadline), TimeUnit.NANOSECONDS)?.let { failures.add("$id: $it") }
                } catch (e: TimeoutException) {
                    failures.add("$id: timed out; launch or process termination not confirmed")
                } catch (e: InterruptedException) {
                    interrupted = true
                    failures.add("$id: shutdown wait interrupted; termination not confirmed")
                } catch (e: ExecutionException) {
                    failures.add("$id: orderly termination could not be verified")
                }
            }
        } finally {
            executor.shutdownNow()
            shutdownCompleted = true
            if (interrupted) Thread.currentThread().interrupt()
        }

        if (failures.isNotEmpty()) {
            val message = "Game-server shutdown incomplete (${failures.joinToString("; ")}). $RECOVERY_ACTION"
            shutdownFailure = message
            logger.error(message)
            throw IllegalStateException(message)
        }
        logger.info("Game-server shutdown complete: all managed launches and processes have stopped.")
    }

    private fun stopForShutdown(id: UUID, managed: ManagedProcess, deadline: Long): String? {
        val process = managed.launched.get(remainingNanos(deadline), TimeUnit.NANOSECONDS) ?: return null
        observeChildren(managed, process)
        var verificationFailure: String? = null
        try {
            requestShutdownStop(id, managed, process).get(remainingNanos(deadline), TimeUnit.NANOSECONDS)
        } catch (e: Exception) {
            verificationFailure = "stop command could not be delivered; world saving not confirmed"
        }
        observeChildren(managed, process)

        if (process.isAlive && !process.waitFor(remainingNanos(deadline), TimeUnit.NANOSECONDS)) {
            return "timed out; process ${process.pid()} may still be running"
        }
        for (child in managed.children.values) {
            if (child.isAlive) {
                try {
                    child.onExit().get(remainingNanos(deadline), TimeUnit.NANOSECONDS)
                } catch (e: TimeoutException) {
                    return "timed out; child process ${child.pid()} is still running"
                }
            }
        }
        if (process.isAlive || managed.children.values.any { it.isAlive }) {
            return "a managed process or child process is still running"
        }
        if (process.exitValue() != 0) {
            return "server exited with code ${process.exitValue()}; verify world saving in the instance logs"
        }
        return verificationFailure ?: if (managed.childInspectionFailed.get()) "could not inspect child processes" else null
    }

    private fun requiresShutdownVerification(managed: ManagedProcess): Boolean =
        managed.shutdownMember || !managed.launched.isDone || managed.process?.isAlive == true ||
            managed.children.values.any { it.isAlive } || managed.childInspectionFailed.get() ||
            managed.shutdownStop.get() != null

    private fun observeChildren(managed: ManagedProcess, process: Process) {
        try {
            process.descendants().use { children ->
                children.forEach { managed.children[it.pid()] = it }
            }
        } catch (e: Exception) {
            managed.childInspectionFailed.set(true)
        }
    }

    private fun requestShutdownStop(id: UUID, managed: ManagedProcess, process: Process): CompletableFuture<Unit> {
        val attempt = CompletableFuture<Unit>()
        val existing = managed.shutdownStop.compareAndExchange(null, attempt)
        if (existing != null) return existing
        thread(name = "Instance-Stop-$id", isDaemon = true) {
            try {
                observeChildren(managed, process)
                writeCommand(id, managed, process, "stop")
                observeChildren(managed, process)
                attempt.complete(Unit)
            } catch (e: Exception) {
                attempt.completeExceptionally(IllegalStateException("Could not deliver the Minecraft stop command"))
                logger.error("Could not send stop to instance $id. $RECOVERY_ACTION")
            }
        }
        return attempt
    }

    private fun writeCommand(id: UUID, managed: ManagedProcess, process: Process, command: String) {
        synchronized(managed.commandLock) {
            if (!process.isAlive) return
            val writer = BufferedWriter(OutputStreamWriter(process.outputStream))
            writer.write(command + "\n")
            writer.flush()
            appendLog(id, "> $command")
        }
    }

    private fun checkAcceptingStarts() {
        check(!shuttingDown) { "Backend is shutting down. Verify game-server termination before restarting Moddex." }
    }

    private fun remainingNanos(deadline: Long): Long = (deadline - System.nanoTime()).coerceAtLeast(0)

    private fun appendLog(id: UUID, line: String) {
        val logList = logs.computeIfAbsent(id) { mutableListOf() }
        synchronized(logList) {
            logList.add(line)
            if (logList.size > MAX_LOG_LINES) {
                logList.removeAt(0)
            }
        }
    }

    private fun buildStartCommand(instance: Instance, directory: Path): List<String> {
        val cmd = mutableListOf<String>()

        val javaBin = instance.javaPath?.takeIf { it.isNotBlank() } ?: "java"
        cmd.add(javaBin)

        instance.javaXmx?.takeIf { it.isNotBlank() }?.let { cmd.add("-Xmx$it") }
        instance.javaXms?.takeIf { it.isNotBlank() }?.let { cmd.add("-Xms$it") }

        // The start entry is the manifest the installation stored once while
        // its state was coherent (see InstanceStartManifestStore): argument
        // file contracts and jar contracts are no longer guessed per start.
        // A present but unreadable or invalid manifest is rejected with
        // guidance instead of falling back to heuristics.
        val entry = startManifestStore.resolveForStart(instance, directory) ?: run {
            // Transition rule for instances created before start manifests
            // were stored (or whose manifest could not be written): fall back
            // to the legacy discovery and point at the migration path. This
            // fallback is deliberate and temporary; new installations always
            // store a manifest when an entry is resolvable.
            logger.warn(
                "Instance ${instance.id} has no stored start manifest " +
                    "(${InstanceStartManifestStore.MANIFEST_FILE_NAME}); it was created before start manifests " +
                    "were stored or the manifest could not be written. Using the legacy start discovery. " +
                    "Reinstall the instance to store a start manifest."
            )
            LoaderStartDiscovery.resolve(instance, directory)
                ?: throw IllegalStateException("No valid server jar found for instance ${instance.name}")
        }
        applyStartEntry(cmd, directory, entry)
        return cmd
    }

    private fun applyStartEntry(cmd: MutableList<String>, directory: Path, entry: StartEntry) {
        when (entry) {
            is StartEntry.ArgumentsFile -> {
                // Modern Forge and NeoForge installers (--installServer) write
                // a launch contract as argument files instead of a single
                // executable server jar; starting such an instance with -jar
                // ignores that contract. The optional user JVM args file is
                // part of the same contract and stays effective when present.
                if (Files.exists(directory.resolve("user_jvm_args.txt"))) {
                    cmd.add("@user_jvm_args.txt")
                }
                cmd.add("@${entry.relativePath}")
                cmd.add("nogui")
            }

            is StartEntry.ServerJar -> {
                cmd.add("-jar")
                cmd.add(entry.relativePath)
                cmd.add("nogui")
            }
        }
    }

    companion object {
        private const val RECOVERY_ACTION =
            "Inspect the instance logs and remaining processes; save and stop surviving servers through their " +
                "administration interface, then verify all have exited before restarting Moddex. No automatic force-kill is used."

        /**
         * The installer writes a platform-specific argument file next to the
         * loader libraries; Windows launches use win_args.txt, everything
         * else uses unix_args.txt.
         */
        internal fun preferredArgsFileName(osName: String): String =
            LoaderStartDiscovery.preferredArgsFileName(osName)
    }
}

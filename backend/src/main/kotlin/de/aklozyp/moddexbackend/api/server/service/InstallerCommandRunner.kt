package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.services.Logger
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Component
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Path
import java.util.LinkedHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

/**
 * Signals that an installer process did not finish within its configured time
 * budget and was terminated. The message names the timeout and the termination
 * outcome only; it carries no command lines, paths, or credentials.
 */
class InstallerCommandTimeoutException(message: String) : RuntimeException(message)

interface InstallerCommandRunner {
    /**
     * Runs one installer command under the runner's time budget and returns the
     * child's exit code. The caller chooses [jobId] (instance id plus a fresh
     * run id) and later uses the same id with [recentOutput] to build the
     * excerpt for its failure messages, so parallel runs stay attributable.
     * Throws [InstallerCommandTimeoutException] when the budget expires.
     */
    fun run(command: List<String>, workingDirectory: Path, jobId: String): Int

    /**
     * Returns up to [maxLines] of the most recent captured output lines of the
     * install job with [jobId], in capture order. The lines are the raw merged
     * process output (each line length-capped at capture time); callers that
     * put them into user-facing messages must sanitize them first.
     */
    fun recentOutput(jobId: String, maxLines: Int): List<String>
}

/**
 * Runs an installer command synchronously under a time budget while capturing
 * the output of every run separately per job id.
 *
 * The budgeted wait uses [Process.waitFor] with a timeout; a process that
 * outlives the budget is first destroyed (orderly termination request), then,
 * after a grace period, terminated forcibly. Every expiry fails the install
 * with [InstallerCommandTimeoutException] instead of waiting indefinitely.
 *
 * Output handling: the merged stdout/stderr of the child is no longer inherited
 * by the backend process. A bounded daemon reader thread per run consumes it
 * into an in-memory, size-capped per-job buffer ([recentOutput]) and mirrors
 * each line into the backend log prefixed with the job id, so the full output
 * stays available to operators and is attributable to one install job even
 * when several installers run in parallel. The reader never blocks
 * indefinitely: bytes are consumed only when [InputStream.available] reports
 * data, and once a termination is requested it stops at its own stop deadline
 * even if a surviving installer descendant keeps writing. Captured content is
 * bounded per line, per job, and across retained jobs; the oldest jobs are
 * evicted first. There is deliberately no retrieval endpoint for these
 * buffers; the user-facing excerpt is built from them by the caller.
 *
 * Limitation: only the direct installer process receives the termination
 * signal. Additional operating-system children spawned by the installer (for
 * example shell or package-manager sub-processes) can outlive it; a
 * process-group based cleanup would be Linux-specific and is deliberately not
 * implemented here. Output of a descendant that keeps running after the direct
 * installer exited is captured only until the direct process's death is
 * observed and the stream is drained.
 */
@Component
class DefaultInstallerCommandRunner(
    private val logger: Logger,
    @Value("\${moddex.installer.timeout-ms:900000}")
    private val timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
    @Value("\${moddex.installer.destroy-grace-ms:10000}")
    private val destroyGraceMillis: Long = DEFAULT_DESTROY_GRACE_MILLIS,
) : InstallerCommandRunner {

    init {
        require(timeoutMillis > 0) { "Installer timeout must be greater than zero" }
        require(destroyGraceMillis > 0) { "Installer destroy grace period must be greater than zero" }
    }

    /** Captured lines of one install job; guarded by [JobLog.lines]. */
    private class JobLog {
        val lines = mutableListOf<String>()
    }

    /**
     * Bounded store of per-job buffers. Insertion order drives eviction, so
     * long-finished jobs free their memory when many newer installs ran since.
     * A still-running job whose buffer is evicted keeps logging into its
     * detached buffer reference; only [recentOutput] loses the older history.
     */
    private val jobLogs = object : LinkedHashMap<String, JobLog>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, JobLog>): Boolean =
            size > MAX_RETAINED_JOBS
    }

    override fun run(command: List<String>, workingDirectory: Path, jobId: String): Int {
        require(jobId.isNotBlank()) { "Installer job id must not be blank" }
        val job = registerJob(jobId)
        // Set when termination begins so the reader stops even if a surviving
        // installer descendant keeps the stream alive; zero means "no stop".
        val readerStopDeadline = AtomicLong(0L)

        val process = ProcessBuilder(command)
            .directory(workingDirectory.toFile())
            .redirectErrorStream(true)
            .redirectInput(ProcessBuilder.Redirect.INHERIT)
            .start()

        val reader = thread(name = "Installer-Output-$jobId", isDaemon = true) {
            readInstallerOutput(process, job, jobId, readerStopDeadline)
        }

        try {
            if (!process.waitFor(timeoutMillis, TimeUnit.MILLISECONDS)) {
                readerStopDeadline.set(readerStopDeadlineNanos())
                terminateStalledProcess(process)
            }
            // The budgeted wait returned true, so the process has exited; this wait
            // releases immediately with its real exit code.
            val exitCode = process.waitFor()
            awaitReaderTermination(reader, jobId)
            return exitCode
        } catch (timeout: InstallerCommandTimeoutException) {
            awaitReaderTermination(reader, jobId)
            throw timeout
        } catch (interrupted: InterruptedException) {
            // The wait was interrupted from outside. The child handling stays as
            // before (no new termination semantics here); the reader stops at its
            // deadline and is awaited so this run cannot leave a leak behind.
            readerStopDeadline.set(System.nanoTime())
            reader.join(READER_AWAIT_MILLIS)
            Thread.currentThread().interrupt()
            throw interrupted
        }
    }

    override fun recentOutput(jobId: String, maxLines: Int): List<String> {
        require(maxLines > 0) { "Excerpt line count must be greater than zero" }
        synchronized(jobLogs) {
            val job = jobLogs[jobId] ?: return emptyList()
            synchronized(job.lines) {
                return job.lines.takeLast(minOf(maxLines, job.lines.size))
            }
        }
    }

    private fun registerJob(jobId: String): JobLog = synchronized(jobLogs) {
        jobLogs.getOrPut(jobId) { JobLog() }
    }

    private fun readerStopDeadlineNanos(): Long =
        System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(2 * destroyGraceMillis + READER_STOP_MARGIN_MILLIS)

    private fun awaitReaderTermination(reader: Thread, jobId: String) {
        reader.join(READER_AWAIT_MILLIS)
        if (reader.isAlive) {
            // Bounded fallback: the reader is a daemon and stops at its own
            // stop deadline even if a surviving descendant keeps writing.
            logger.warn("Installer output reader for job $jobId did not finish in time; it stops on its own bound.")
        }
    }

    private fun terminateStalledProcess(process: Process): Nothing {
        process.destroy()
        if (process.waitFor(destroyGraceMillis, TimeUnit.MILLISECONDS)) {
            throw InstallerCommandTimeoutException(
                "The installer process timed out after $timeoutMillis ms and was terminated."
            )
        }
        process.destroyForcibly()
        val stopped = process.waitFor(destroyGraceMillis, TimeUnit.MILLISECONDS)
        val outcome = if (stopped) {
            "was terminated forcefully."
        } else {
            "received a forceful termination signal, but it may still be running (pid ${process.pid()}); " +
                "stop it manually before retrying."
        }
        throw InstallerCommandTimeoutException(
            "The installer process timed out after $timeoutMillis ms and $outcome"
        )
    }

    /**
     * Consumes the merged child output without ever blocking indefinitely.
     * Bytes are read only while [InputStream.available] reports data, so the
     * loop always returns to its stop check; it ends when the direct process
     * died and the stream is drained, or at the stop deadline set when
     * termination begins. A partial final line (no trailing newline) is
     * flushed, because installer error output often ends without one.
     */
    private fun readInstallerOutput(
        process: Process,
        job: JobLog,
        jobId: String,
        readerStopDeadline: AtomicLong,
    ) {
        val stream = process.inputStream
        val chunk = ByteArray(READ_CHUNK_BYTES)
        val lineBuffer = ByteArrayOutputStream()
        var lineTruncated = false
        try {
            while (true) {
                val stopDeadline = readerStopDeadline.get()
                if (stopDeadline != 0L && System.nanoTime() >= stopDeadline) break
                val available = stream.available()
                when {
                    available > 0 -> {
                        val read = stream.read(chunk, 0, minOf(chunk.size, available))
                        if (read < 0) break
                        for (index in 0 until read) {
                            val byte = chunk[index].toInt() and 0xFF
                            if (byte == '\n'.code) {
                                appendCapturedLine(job, jobId, lineBuffer.toByteArray(), lineTruncated)
                                lineBuffer.reset()
                                lineTruncated = false
                            } else if (lineBuffer.size() < MAX_LINE_BYTES) {
                                lineBuffer.write(byte)
                            } else {
                                lineTruncated = true
                            }
                        }
                    }
                    !process.isAlive && stream.available() == 0 -> break
                    else -> Thread.sleep(READER_POLL_MILLIS)
                }
            }
        } catch (_: InterruptedException) {
            // Stop requested or JVM shutdown; captured lines stay in the store.
        } catch (_: IOException) {
            // The stream broke during teardown; captured lines stay in the store.
        } finally {
            if (lineBuffer.size() > 0 || lineTruncated) {
                appendCapturedLine(job, jobId, lineBuffer.toByteArray(), lineTruncated)
            }
        }
    }

    private fun appendCapturedLine(job: JobLog, jobId: String, rawBytes: ByteArray, truncated: Boolean) {
        var line = String(rawBytes, StandardCharsets.UTF_8).trimEnd('\r')
        if (truncated) line += TRUNCATED_MARKER
        if (line.isBlank()) return
        synchronized(job.lines) {
            job.lines.add(line)
            if (job.lines.size > MAX_LINES_PER_JOB) {
                job.lines.removeAt(0)
            }
        }
        // Mirror the attributed line into the backend log, so the full installer
        // output remains available to operators (as with the former inheritIO)
        // while being attributable to this job even across parallel installs.
        logger.info("Installer[$jobId]: $line")
    }

    companion object {
        /**
         * Default budget for one installer run. Installers download and extract
         * their artifacts, so the budget must exceed a slow-but-working install;
         * 15 minutes was chosen over 10 to keep headroom for weak connections.
         */
        const val DEFAULT_TIMEOUT_MILLIS = 900_000L

        /**
         * Grace period between the orderly termination request and the forced
         * termination of a stalled installer process.
         */
        const val DEFAULT_DESTROY_GRACE_MILLIS = 10_000L

        /**
         * Lines retained per install job; the oldest line is dropped first once
         * the bound is reached (500 lines at a 2000-byte line cap bound one
         * job's buffer at roughly 1 MB, so captured output can never grow
         * unbounded even for chatty or stalled installers).
         */
        internal const val MAX_LINES_PER_JOB = 500

        /** Upper length of one captured line in bytes before it is marked truncated. */
        internal const val MAX_LINE_BYTES = 2_000

        /**
         * How many jobs keep their captured output for error excerpts before
         * the oldest job's buffer is evicted.
         */
        internal const val MAX_RETAINED_JOBS = 32

        /** Extra drain time the reader gets after the termination window. */
        private const val READER_STOP_MARGIN_MILLIS = 5_000L

        /** Wait for the reader thread after the process ended or on teardown. */
        private const val READER_AWAIT_MILLIS = 10_000L

        /** Idle poll interval of the output reader. */
        private const val READER_POLL_MILLIS = 20L

        private const val READ_CHUNK_BYTES = 8_192

        /** Marker appended to a captured line that exceeded the line cap. */
        internal const val TRUNCATED_MARKER = "...<truncated>"
    }
}

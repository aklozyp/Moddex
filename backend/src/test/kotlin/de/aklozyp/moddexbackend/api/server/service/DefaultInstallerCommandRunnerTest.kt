package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.services.Logger
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.condition.EnabledOnOs
import org.junit.jupiter.api.condition.OS
import org.junit.jupiter.api.io.TempDir
import org.mockito.Mockito
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Exercises the installer time budget and the per-job output capture with
 * short-lived shell test doubles (sleep loops and echo commands, not
 * installers or game servers). The scripts hand out their own pid or print
 * distinguishable lines so the tests can verify termination, separation, and
 * capture without touching real installers or production paths.
 */
@EnabledOnOs(OS.LINUX, OS.MAC)
class DefaultInstallerCommandRunnerTest {

    @TempDir
    lateinit var tempDir: Path

    private val logger: Logger = Mockito.mock(Logger::class.java)

    private fun runner(timeoutMillis: Long = 10_000, destroyGraceMillis: Long = 1_000) =
        DefaultInstallerCommandRunner(logger, timeoutMillis = timeoutMillis, destroyGraceMillis = destroyGraceMillis)

    @Test
    fun `a command finishing within the budget keeps its exit code and side effects`() {
        val jobId = "budget-job"

        val exitCode = runner().run(listOf("sh", "-c", "echo ok > result.txt"), tempDir, jobId)

        assertThat(exitCode).isZero()
        assertThat(Files.readString(tempDir.resolve("result.txt")).trim()).isEqualTo("ok")
    }

    @Test
    fun `a nonzero exit code within the budget is passed through unwrapped`() {
        val jobId = "nonzero-job"

        // The child writes its marker into a file; its console output is
        // captured per job instead of leaking into the test process's stdout.
        val exitCode = runner().run(listOf("sh", "-c", "echo starting > started.txt; exit 3"), tempDir, jobId)

        assertThat(exitCode).isEqualTo(3)
        assertThat(Files.exists(tempDir.resolve("started.txt"))).isTrue()
    }

    @Test
    fun `a stalled process is terminated after the budget and reports the timeout`() {
        val runner = runner(timeoutMillis = 250, destroyGraceMillis = 2_000)
        val jobId = "stalled-job"

        val error = assertThrows<InstallerCommandTimeoutException> {
            runner.run(listOf("sh", "-c", "echo \$\$ > pid.txt; while true; do sleep 0.1; done"), tempDir, jobId)
        }

        assertThat(error.message).contains("timed out after 250 ms", "was terminated")
        assertThat(Files.exists(tempDir.resolve("pid.txt"))).isTrue()
        assertThat(isProcessAlive()).isFalse()
    }

    @Test
    fun `a process exiting during the grace period is not force-terminated`() {
        val runner = runner(timeoutMillis = 250, destroyGraceMillis = 5_000)
        val jobId = "graceful-job"

        val error = assertThrows<InstallerCommandTimeoutException> {
            runner.run(
                listOf(
                    "sh",
                    "-c",
                    "trap 'touch graceful-exit.marker; exit 7' TERM; echo \$\$ > pid.txt; while true; do sleep 0.1; done",
                ),
                tempDir,
                jobId,
            )
        }

        // The trap handler ran after the orderly termination request, so the
        // grace period did its job and the forceful path was never needed.
        assertThat(Files.exists(tempDir.resolve("graceful-exit.marker"))).isTrue()
        assertThat(error.message).contains("timed out after 250 ms", "was terminated.")
        assertThat(error.message).doesNotContain("forcefully")
        assertThat(isProcessAlive()).isFalse()
    }

    @Test
    fun `a process surviving the orderly termination is destroyed forcibly`() {
        val runner = runner(timeoutMillis = 250, destroyGraceMillis = 400)
        val jobId = "forced-job"

        val error = assertThrows<InstallerCommandTimeoutException> {
            runner.run(
                listOf("sh", "-c", "trap '' TERM; echo \$\$ > pid.txt; while true; do :; done"),
                tempDir,
                jobId,
            )
        }

        assertThat(error.message).contains("timed out after 250 ms", "forcefully")
        assertThat(isProcessAlive()).isFalse()
    }

    @Test
    fun `a successful run captures its merged output per job and flushes a final partial line`() {
        val runner = runner()
        val jobId = "success-job"

        val exitCode = runner.run(
            listOf("sh", "-c", "echo line-one; echo line-two >&2; printf 'partial-tail'"),
            tempDir,
            jobId,
        )

        assertThat(exitCode).isZero()
        assertThat(runner.recentOutput(jobId, 10)).containsExactly("line-one", "line-two", "partial-tail")
        // A different job id has no captured output of this run.
        assertThat(runner.recentOutput("other-job", 10)).isEmpty()
    }

    @Test
    fun `a failing run keeps its captured output available for the error excerpt`() {
        val runner = runner()
        val jobId = "failing-job"

        val exitCode = runner.run(
            listOf("sh", "-c", "echo booting; echo crashed-on-missing-library >&2; exit 3"),
            tempDir,
            jobId,
        )

        assertThat(exitCode).isEqualTo(3)
        assertThat(runner.recentOutput(jobId, 10)).containsExactly("booting", "crashed-on-missing-library")
    }

    @Test
    fun `parallel install jobs keep their captured outputs strictly separated`() {
        val runner = runner()
        val jobA = "parallel-job-a"
        val jobB = "parallel-job-b"
        val startGate = CountDownLatch(1)
        var exitA = -1
        var exitB = -1

        val threadA = thread {
            startGate.await()
            exitA = runner.run(listOf("sh", "-c", "for i in \$(seq 1 25); do echo A\$i; sleep 0.01; done"), tempDir, jobA)
        }
        val threadB = thread {
            startGate.await()
            exitB = runner.run(listOf("sh", "-c", "for i in \$(seq 1 25); do echo B\$i; sleep 0.01; done"), tempDir, jobB)
        }
        startGate.countDown()
        threadA.join(20_000)
        threadB.join(20_000)

        assertThat(exitA).isZero()
        assertThat(exitB).isZero()
        // Both runs overlap in time, yet each job's log holds exactly its own
        // lines in capture order with no lines of the other job mixed in.
        assertThat(runner.recentOutput(jobA, 100))
            .containsExactlyElementsOf((1..25).map { "A$it" })
            .noneMatch { it.startsWith("B") }
        assertThat(runner.recentOutput(jobB, 100))
            .containsExactlyElementsOf((1..25).map { "B$it" })
            .noneMatch { it.startsWith("A") }
    }

    @Test
    fun `a timeout stops the output reader and still leaves a bounded excerpt`() {
        val runner = runner(timeoutMillis = 250, destroyGraceMillis = 500)
        val jobId = "timeout-reader-job"

        val error = assertThrows<InstallerCommandTimeoutException> {
            runner.run(listOf("sh", "-c", "while true; do echo tick; sleep 0.02; done"), tempDir, jobId)
        }

        assertThat(error.message).contains("timed out after 250 ms")
        // The excerpt for the failure message is available and attributed.
        assertThat(runner.recentOutput(jobId, 10)).isNotEmpty().allMatch { it.startsWith("tick") }

        // No reader thread leaks after the terminated run.
        assertThat(awaitNoInstallerReaderThreads()).isTrue()
    }

    @Test
    fun `an overlong line is captured truncated instead of growing the buffer`() {
        val runner = runner()
        val jobId = "long-line-job"

        val exitCode = runner.run(listOf("sh", "-c", "head -c 5000 </dev/zero | tr '\\0' 'x'"), tempDir, jobId)

        assertThat(exitCode).isZero()
        val captured = runner.recentOutput(jobId, 10)
        assertThat(captured).hasSize(1)
        assertThat(captured.single()).hasSizeLessThanOrEqualTo(DefaultInstallerCommandRunner.MAX_LINE_BYTES + 32)
        assertThat(captured.single()).endsWith(DefaultInstallerCommandRunner.TRUNCATED_MARKER)
    }

    @Test
    fun `captured output stays bounded and the oldest lines are dropped first`() {
        val runner = runner()
        val jobId = "bounded-job"

        val exitCode = runner.run(listOf("sh", "-c", "for i in \$(seq 1 600); do echo L\$i; done"), tempDir, jobId)

        assertThat(exitCode).isZero()
        val captured = runner.recentOutput(jobId, DefaultInstallerCommandRunner.MAX_LINES_PER_JOB)
        assertThat(captured).hasSize(DefaultInstallerCommandRunner.MAX_LINES_PER_JOB)
        // 600 lines were produced; the ring kept the newest 500.
        assertThat(captured.first()).isEqualTo("L101")
        assertThat(captured.last()).isEqualTo("L600")
    }

    /**
     * kill -0 fails once the JVM has reaped the terminated child, which the
     * runner does through its budgeted waits before throwing.
     */
    private fun isProcessAlive(): Boolean {
        val pid = Files.readString(tempDir.resolve("pid.txt")).trim()
        val check = ProcessBuilder("sh", "-c", "kill -0 $pid").start()
        return check.waitFor() == 0
    }

    /**
     * Polls for the bound on reader-thread teardown: after a terminated run
     * the reader ends once the child is gone, typically within milliseconds.
     */
    private fun awaitNoInstallerReaderThreads(): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (System.nanoTime() < deadline) {
            if (installerReaderThreads().isEmpty()) return true
            Thread.sleep(50)
        }
        return installerReaderThreads().isEmpty()
    }

    private fun installerReaderThreads(): List<Thread> {
        val threads = arrayOfNulls<Thread>(Thread.activeCount() + 16).also { Thread.enumerate(it) }
        return threads.filterNotNull()
            .filter { it.isAlive && it.name.startsWith("Installer-Output-") }
    }
}

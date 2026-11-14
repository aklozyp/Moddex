package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.springframework.context.annotation.AnnotationConfigApplicationContext
import org.springframework.core.env.MapPropertySource
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.function.Supplier
import java.util.stream.Stream
import kotlin.concurrent.thread

class ProcessManagerServiceTest {
    private val instanceService = mockk<InstanceService>()
    private val eulaService = mockk<EulaService>()
    private val logger = mockk<Logger>(relaxed = true)
    private val launcher = mockk<ServerProcessLauncher>()
    private val startManifestStore = InstanceStartManifestStore(jacksonObjectMapper(), logger)
    private var service = newService()
    private lateinit var directory: Path
    private val testThreads = Executors.newCachedThreadPool { task ->
        Thread(task, "ProcessManager-Test").apply { isDaemon = true }
    }

    @BeforeEach
    fun createFixture() {
        directory = Files.createDirectories(Path.of("target", "process-manager-${UUID.randomUUID()}"))
        Files.createFile(directory.resolve("server.jar"))
    }

    @AfterEach
    fun cleanFixture() {
        testThreads.shutdownNow()
        Files.walk(directory).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach { Files.delete(it) }
        }
    }

    @Test
    fun `start rejects an unaccepted EULA with a dedicated exception`() {
        val id = UUID.randomUUID()
        every { eulaService.isEulaAccepted(id) } returns false

        assertThrows<EulaNotAcceptedException> { service.startInstance(id) }

        service.shutdown()
        verify(exactly = 0) { launcher.start(any(), any()) }
    }

    @Test
    fun `server start passes the selected Java executable unchanged as one argument`() {
        val process = FakeProcess()
        val id = prepare(process)
        val javaPath = directory.resolve("Selected Java 21").resolve("bin").resolve("java").toString()
        every { instanceService.getInstanceById(id) } returns Instance(id = id, javaPath = javaPath)

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf(javaPath, "-jar", "server.jar", "nogui"), directory) }
    }

    @Test
    fun `neoforge start uses the installer argument file for the current platform`() {
        val process = FakeProcess()
        val id = prepare(process)
        val argsRef = installLoaderArgs("net/neoforged/neoforge", "20.4.237")
        every { instanceService.getInstanceById(id) } returns
            Instance(
                id = id,
                modLoader = ModLoader.NEOFORGE,
                gameVersion = "1.20.4",
                modLoaderVersion = "20.4.237",
                javaXmx = "4G",
                javaXms = "2G",
            )

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) {
            launcher.start(listOf("java", "-Xmx4G", "-Xms2G", "@user_jvm_args.txt", argsRef, "nogui"), directory)
        }
    }

    @Test
    fun `modern forge start prefers the argument file over a jar and resolves the build-only version`() {
        // The UI records the forge build number only; the library directory
        // carries "<gameVersion>-<build>". With two installed builds the
        // declared one must win, even though 47.2 sorts above 47.10.
        Files.createFile(directory.resolve("forge-1.20.1-47.2.0.jar"))
        val process = FakeProcess()
        val id = prepare(process)
        installLoaderArgs("net/minecraftforge/forge", "1.20.1-47.2.0")
        val newerArgs = installLoaderArgs("net/minecraftforge/forge", "1.20.1-47.10.0")
        every { instanceService.getInstanceById(id) } returns
            Instance(
                id = id,
                modLoader = ModLoader.FORGE,
                gameVersion = "1.20.1",
                modLoaderVersion = "47.10.0",
            )

        service.startInstance(id)
        service.shutdown()

        val command = slot<List<String>>()
        verify(exactly = 1) { launcher.start(capture(command), directory) }
        assertThat(command.captured).contains("@user_jvm_args.txt", newerArgs, "nogui")
        assertThat(command.captured).doesNotContain("@libraries/net/minecraftforge/forge/1.20.1-47.2.0/")
    }

    @Test
    fun `argument file start works without user jvm args`() {
        val process = FakeProcess()
        val id = prepare(process)
        val argsRef = installLoaderArgs("net/neoforged/neoforge", "20.4.237")
        Files.delete(directory.resolve("user_jvm_args.txt"))
        every { instanceService.getInstanceById(id) } returns Instance(id = id, modLoader = ModLoader.NEOFORGE)

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf("java", argsRef, "nogui"), directory) }
    }

    @Test
    fun `old forge without argument files keeps the jar fallback`() {
        Files.delete(directory.resolve("server.jar"))
        Files.createFile(directory.resolve("forge-1.16.5-36.2.39.jar"))
        // Old forge installs keep a libraries tree but never write args files.
        val oldLibraries = directory.resolve("libraries").resolve("net").resolve("minecraftforge").resolve("forge").resolve("1.16.5-36.2.39")
        Files.createDirectories(oldLibraries)
        val process = FakeProcess()
        val id = prepare(process)
        every { instanceService.getInstanceById(id) } returns
            Instance(id = id, modLoader = ModLoader.FORGE, gameVersion = "1.16.5", modLoaderVersion = "36.2.39")

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf("java", "-jar", "forge-1.16.5-36.2.39.jar", "nogui"), directory) }
    }

    @Test
    fun `argument file discovery prefers the declared loader group`() {
        val process = FakeProcess()
        val id = prepare(process)
        installLoaderArgs("net/minecraftforge/forge", "1.20.1-47.2.0")
        val neoforgeArgs = installLoaderArgs("net/neoforged/neoforge", "20.4.237")
        every { instanceService.getInstanceById(id) } returns
            Instance(id = id, modLoader = ModLoader.NEOFORGE, gameVersion = "1.20.4", modLoaderVersion = "20.4.237")

        service.startInstance(id)
        service.shutdown()

        val command = slot<List<String>>()
        verify(exactly = 1) { launcher.start(capture(command), directory) }
        assertThat(command.captured).contains(neoforgeArgs)
        assertThat(command.captured).doesNotContain("@libraries/net/minecraftforge/forge/")
    }

    @Test
    fun `preferred argument file name follows the platform`() {
        assertThat(ProcessManagerService.preferredArgsFileName("Windows 11")).isEqualTo("win_args.txt")
        assertThat(ProcessManagerService.preferredArgsFileName("Linux")).isEqualTo("unix_args.txt")
        assertThat(ProcessManagerService.preferredArgsFileName("Mac OS X")).isEqualTo("unix_args.txt")
    }

    @Test
    fun `manifested start uses the stored jar entry instead of the heuristic jar search`() {
        // For a loader-less instance the heuristic would pick server.jar (and
        // any forge-named leftover before that); the manifest pins the entry
        // the installation resolved instead of guessing per start.
        Files.createFile(directory.resolve("my-server.jar"))
        Files.createFile(directory.resolve("forge-9.9.9-decoy.jar"))
        storeManifest(InstanceStartManifest(loader = ModLoader.VANILLA, jarPath = "my-server.jar"))
        val process = FakeProcess()
        val id = prepare(process)

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf("java", "-jar", "my-server.jar", "nogui"), directory) }
    }

    @Test
    fun `manifested start uses the stored argument file even where discovery would find none`() {
        // The manifest entry lives in a library group the legacy discovery
        // never scans; the decoy server.jar would win the heuristic jar
        // fallback. Only the stored manifest resolves this contract.
        val argsFile = "libraries/net/example/custom/1.0.0/" +
            ProcessManagerService.preferredArgsFileName(System.getProperty("os.name"))
        val versionDir = directory.resolve("libraries").resolve("net/example/custom/1.0.0")
        Files.createDirectories(versionDir)
        Files.createFile(versionDir.resolve(ProcessManagerService.preferredArgsFileName(System.getProperty("os.name"))))
        storeManifest(InstanceStartManifest(loader = ModLoader.NEOFORGE, argsFile = argsFile))
        val process = FakeProcess()
        val id = prepare(process)
        every { instanceService.getInstanceById(id) } returns
            Instance(id = id, modLoader = ModLoader.NEOFORGE, gameVersion = "1.20.4", modLoaderVersion = "20.4.237")

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf("java", "@$argsFile", "nogui"), directory) }
    }

    @Test
    fun `manifested start with an unreadable manifest is guided and never falls back to the jar search`() {
        Files.writeString(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME), "{ broken")
        val process = FakeProcess()
        val id = prepare(process)

        val error = assertThrows<IllegalStateException> { service.startInstance(id) }

        assertTrue(error.message!!.contains("could not be read"))
        assertTrue(error.message!!.contains("reinstall"))
        verify(exactly = 0) { launcher.start(any(), any()) }
        service.shutdown()
    }

    @Test
    fun `manifested start with a missing referenced jar is guided and never falls back to the jar search`() {
        // server.jar is present and would satisfy the heuristic; the manifest
        // contract must be rejected with guidance instead of guessed around.
        storeManifest(InstanceStartManifest(loader = ModLoader.VANILLA, jarPath = "missing-server.jar"))
        val process = FakeProcess()
        val id = prepare(process)

        val error = assertThrows<IllegalStateException> { service.startInstance(id) }

        assertTrue(error.message!!.contains("missing-server.jar"))
        assertTrue(error.message!!.contains("Restore it from a backup or reinstall"))
        verify(exactly = 0) { launcher.start(any(), any()) }
        service.shutdown()
    }

    @Test
    fun `manifested start with a stale loader is rejected with reinstall guidance`() {
        storeManifest(InstanceStartManifest(loader = ModLoader.FORGE, jarPath = "server.jar"))
        val process = FakeProcess()
        val id = prepare(process)
        every { instanceService.getInstanceById(id) } returns Instance(id = id, modLoader = ModLoader.NEOFORGE)

        val error = assertThrows<IllegalStateException> { service.startInstance(id) }

        assertTrue(error.message!!.contains("created for loader FORGE"))
        assertTrue(error.message!!.contains("now declares NEOFORGE"))
        assertTrue(error.message!!.contains("Reinstall the instance"))
        verify(exactly = 0) { launcher.start(any(), any()) }
        service.shutdown()
    }

    @Test
    fun `manifested start with a path traversal entry is rejected`() {
        // The referenced file exists outside the instance directory; the
        // manifest path must never resolve there. The name is unique per run
        // because the parent directory is shared by every test execution on
        // this checkout, so parallel runs must not collide on the fixture.
        val outsideName = "outside-of-instance-${UUID.randomUUID()}.jar"
        val outside = directory.parent.resolve(outsideName)
        Files.createFile(outside)
        try {
            storeManifest(InstanceStartManifest(loader = ModLoader.VANILLA, jarPath = "../$outsideName"))
            val process = FakeProcess()
            val id = prepare(process)

            val error = assertThrows<IllegalStateException> { service.startInstance(id) }

            assertThat(error.message).contains("invalid server jar path")
            assertThat(error.message).contains("Reinstall the instance")
            verify(exactly = 0) { launcher.start(any(), any()) }
        } finally {
            Files.deleteIfExists(outside)
        }
        service.shutdown()
    }

    @Test
    fun `instance without a manifest keeps the legacy discovery and logs the migration hint`() {
        // Transition rule for instances created before start manifests were
        // stored: the legacy discovery still starts them, with a logged hint.
        val process = FakeProcess()
        val id = prepare(process)

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf("java", "-jar", "server.jar", "nogui"), directory) }
        verify {
            logger.warn(
                withArg {
                    it.contains("no stored start manifest") && it.contains("legacy start discovery") &&
                        it.contains("Reinstall the instance")
                },
            )
        }
    }

    @Test
    fun `vanilla start uses the manifest the installer store recorded`() {
        val process = FakeProcess()
        val id = prepare(process)
        every { instanceService.getInstanceById(id) } returns Instance(id = id, modLoader = ModLoader.VANILLA)
        startManifestStore.record(Instance(id = id, modLoader = ModLoader.VANILLA, gameVersion = "1.20.1"), directory)
        val manifest = jacksonObjectMapper()
            .readValue<InstanceStartManifest>(directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME).toFile())
        assertEquals(ModLoader.VANILLA, manifest.loader)
        assertEquals("server.jar", manifest.jarPath)

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf("java", "-jar", "server.jar", "nogui"), directory) }
    }

    private fun storeManifest(manifest: InstanceStartManifest) {
        jacksonObjectMapper().writeValue(
            directory.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME).toFile(),
            manifest,
        )
    }

    @Test
    fun `vanilla start uses the startable server jar and never the installer-named one`() {
        // The old vanilla artifact name must not win over the startable jar,
        // even if a leftover file with the installer name is still present.
        Files.createFile(directory.resolve("server-installer.jar"))
        val process = FakeProcess()
        val id = prepare(process)
        every { instanceService.getInstanceById(id) } returns Instance(id = id, modLoader = ModLoader.VANILLA)

        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf("java", "-jar", "server.jar", "nogui"), directory) }
    }

    @Test
    fun `fresh vanilla instance starts only after explicit eula acceptance`() {
        // Creation prepares a fresh vanilla instance without running a server,
        // so no eula.txt exists yet: the first start must be rejected until the
        // user accepts the EULA explicitly; the rejection must not leave state
        // behind that blocks the retry.
        val process = FakeProcess()
        val id = prepare(process)
        every { instanceService.getInstanceById(id) } returns Instance(id = id, modLoader = ModLoader.VANILLA)
        every { eulaService.isEulaAccepted(id) } returns false

        assertThrows<EulaNotAcceptedException> { service.startInstance(id) }
        verify(exactly = 0) { launcher.start(any(), directory) }

        // After the explicit acceptance the start resolves the startable jar.
        every { eulaService.isEulaAccepted(id) } returns true
        service.startInstance(id)
        service.shutdown()

        verify(exactly = 1) { launcher.start(listOf("java", "-jar", "server.jar", "nogui"), directory) }
    }

    @Test
    fun `shutdown with no processes is idempotent and permanently rejects starts`() {
        service.shutdown()
        service.shutdown()

        assertThrows<IllegalStateException> { service.startInstance(UUID.randomUUID()) }
        verify(exactly = 0) { launcher.start(any(), any()) }
    }

    @Test
    fun `shutdown sends stop to every active server and waits for exit without force killing`() {
        val processes = List(3) { FakeProcess() }
        val ids = processes.map { start(it) }

        service.shutdown()
        service.shutdown()

        processes.forEach {
            assertEquals("stop\n", it.commands())
            assertFalse(it.alive.get())
            assertTrue(it.waits.isNotEmpty())
            assertEquals(0, it.forceKills.get())
            assertEquals(0, it.terminations.get())
        }
        ids.forEach { assertEquals("STOPPED", service.getStatus(it)) }
    }

    @Test
    fun `already exited processes need no stop and do not turn an old crash into a shutdown failure`() {
        val process = FakeProcess(exitCode = 17)
        start(process)
        process.alive.set(false)
        service.rejectStartsOnContextClose()

        service.shutdown()

        assertEquals("", process.commands())
        assertTrue(process.waits.isEmpty())
    }

    @Test
    fun `normal stop remains asynchronous and uses the same Minecraft command`() {
        val process = FakeProcess()
        val id = start(process)

        service.sendCommand(id, "say hello")
        service.stopInstance(id)

        assertEquals("say hello\nstop\n", process.commands())
        assertTrue(process.alive.get())
        assertTrue(process.waits.isEmpty())
        service.shutdown()
    }

    @Test
    fun `log snapshot is a consistent copy of the echoed commands`() {
        val process = FakeProcess()
        val id = start(process)

        service.sendCommand(id, "save-all")
        val snapshot = service.getLogSnapshot(id)

        assertThat(snapshot).containsExactly("> save-all")

        // The snapshot is a copy: later console activity does not change it,
        // and an unknown instance reports an empty buffer instead of failing.
        service.sendCommand(id, "say hello")
        assertThat(snapshot).doesNotContain("> say hello")
        assertThat(service.getLogSnapshot(id)).containsExactly("> save-all", "> say hello")
        assertThat(service.getLogSnapshot(UUID.randomUUID())).isEmpty()
        service.shutdown()
    }

    @Test
    fun `deletion reservation is refused while the game server is alive`() {
        val process = FakeProcess()
        val id = start(process)

        assertThat(service.beginDeletion(id)).isFalse()

        assertTrue(process.alive.get())
        service.shutdown()
    }

    @Test
    fun `deletion reservation is refused while a launch is still in flight`() {
        val process = FakeProcess()
        val id = prepare(process)
        val launching = CountDownLatch(1)
        val release = CountDownLatch(1)
        every { launcher.start(any(), directory) } answers {
            launching.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            process
        }
        val start = testThreads.submit { service.startInstance(id) }
        try {
            assertTrue(launching.await(2, TimeUnit.SECONDS))
            // The reserved-but-unspawned launch is invisible to getStatus, so
            // the deletion gate must look at the reservation itself.
            assertThat(service.beginDeletion(id)).isFalse()
        } finally {
            release.countDown()
        }
        start.get(2, TimeUnit.SECONDS)
        service.shutdown()
    }

    @Test
    fun `deletion reservation is refused while a child process is alive`() {
        val child = mockk<ProcessHandle>()
        every { child.pid() } returns 1234
        every { child.isAlive } returns true
        val process = FakeProcess(children = listOf(child))
        val id = start(process)
        process.alive.set(false)

        assertThat(service.beginDeletion(id)).isFalse()

        // The surviving child also keeps the shutdown contract reporting a
        // failure, consistent with the start gate.
        assertThrows<IllegalStateException> { service.shutdown() }
    }

    @Test
    fun `deletion reservation is refused when child termination could not be verified`() {
        val process = FakeProcess().apply { descendantFailure = IllegalStateException("token=secret") }
        val id = start(process)
        process.alive.set(false)

        assertThat(service.beginDeletion(id)).isFalse()

        assertThrows<IllegalStateException> { service.shutdown() }
    }

    @Test
    fun `start is rejected while a deletion reservation is held and allowed again after release`() {
        val stopped = FakeProcess()
        val id = start(stopped)
        stopped.alive.set(false)

        assertTrue(service.beginDeletion(id))
        val rejection = assertThrows<IllegalStateException> { service.startInstance(id) }
        assertTrue(rejection.message!!.contains("being deleted"))
        // Only the original start reached the launcher; the rejected one never did.
        verify(exactly = 1) { launcher.start(any(), directory) }

        service.endDeletion(id)
        val restarted = FakeProcess()
        every { launcher.start(any(), directory) } returns restarted
        service.startInstance(id)
        service.shutdown()

        verify(exactly = 2) { launcher.start(any(), directory) }
        assertEquals("stop\n", restarted.commands())
        assertFalse(restarted.alive.get())
    }

    @Test
    fun `a second deletion reservation cannot be taken while one is held`() {
        // An instance that was never started is deletable, but only one
        // reservation can exist at a time, and releasing it restores that.
        val id = UUID.randomUUID()
        assertTrue(service.beginDeletion(id))
        assertThat(service.beginDeletion(id)).isFalse()
        service.endDeletion(id)
        assertTrue(service.beginDeletion(id))
        service.endDeletion(id)
    }

    @Test
    fun `restore reservation is refused while the game server is alive`() {
        val process = FakeProcess()
        val id = start(process)

        assertThat(service.beginRestore(id)).isFalse()

        assertTrue(process.alive.get())
        service.shutdown()
    }

    @Test
    fun `restore reservation is refused while a launch is still in flight`() {
        val process = FakeProcess()
        val id = prepare(process)
        val launching = CountDownLatch(1)
        val release = CountDownLatch(1)
        every { launcher.start(any(), directory) } answers {
            launching.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            process
        }
        val start = testThreads.submit { service.startInstance(id) }
        try {
            assertTrue(launching.await(2, TimeUnit.SECONDS))
            // The reserved-but-unspawned launch is invisible to getStatus, so
            // the restore gate must look at the reservation itself.
            assertThat(service.beginRestore(id)).isFalse()
        } finally {
            release.countDown()
        }
        start.get(2, TimeUnit.SECONDS)
        service.shutdown()
    }

    @Test
    fun `restore reservation is refused while a child process is alive`() {
        val child = mockk<ProcessHandle>()
        every { child.pid() } returns 1234
        every { child.isAlive } returns true
        val process = FakeProcess(children = listOf(child))
        val id = start(process)
        process.alive.set(false)

        assertThat(service.beginRestore(id)).isFalse()

        assertThrows<IllegalStateException> { service.shutdown() }
    }

    @Test
    fun `restore reservation is refused when child termination could not be verified`() {
        val process = FakeProcess().apply { descendantFailure = IllegalStateException("token=secret") }
        val id = start(process)
        process.alive.set(false)

        assertThat(service.beginRestore(id)).isFalse()

        assertThrows<IllegalStateException> { service.shutdown() }
    }

    @Test
    fun `start is rejected while a restore reservation is held and allowed again after release`() {
        val stopped = FakeProcess()
        val id = start(stopped)
        stopped.alive.set(false)

        assertTrue(service.beginRestore(id))
        val rejection = assertThrows<IllegalStateException> { service.startInstance(id) }
        assertTrue(rejection.message!!.contains("being restored"))
        // Only the original start reached the launcher; the rejected one never did.
        verify(exactly = 1) { launcher.start(any(), directory) }

        service.endRestore(id)
        val restarted = FakeProcess()
        every { launcher.start(any(), directory) } returns restarted
        service.startInstance(id)
        service.shutdown()

        verify(exactly = 2) { launcher.start(any(), directory) }
        assertEquals("stop\n", restarted.commands())
        assertFalse(restarted.alive.get())
    }

    @Test
    fun `deletion reservation is refused while a restore reservation is held`() {
        val id = UUID.randomUUID()

        assertTrue(service.beginRestore(id))
        assertThat(service.beginDeletion(id)).isFalse()
        service.endRestore(id)

        assertTrue(service.beginDeletion(id))
        service.endDeletion(id)
    }

    @Test
    fun `restore reservation is refused while a deletion reservation is held`() {
        val id = UUID.randomUUID()

        assertTrue(service.beginDeletion(id))
        assertThat(service.beginRestore(id)).isFalse()
        service.endDeletion(id)

        assertTrue(service.beginRestore(id))
        service.endRestore(id)
    }

    @Test
    fun `a second restore reservation cannot be taken while one is held`() {
        val id = UUID.randomUUID()
        assertTrue(service.beginRestore(id))
        assertThat(service.beginRestore(id)).isFalse()
        service.endRestore(id)
        assertTrue(service.beginRestore(id))
        service.endRestore(id)
    }

    @Test
    fun `explicit kill remains available but is never part of orderly shutdown`() {
        val process = FakeProcess()
        val id = start(process)

        service.killInstance(id)
        service.shutdown()

        assertEquals(1, process.forceKills.get())
        assertEquals("", process.commands())
        assertEquals("STOPPED", service.getStatus(id))
    }

    @Test
    fun `Spring context close invokes coordination and closes the start gate`() {
        val process = FakeProcess()
        val id = prepare(process)
        val context = AnnotationConfigApplicationContext()
        context.environment.propertySources.addFirst(
            MapPropertySource("shutdown-test", mapOf("moddex.process.shutdown-timeout-ms" to "2000"))
        )
        context.registerBean("instanceService", InstanceService::class.java, Supplier { instanceService })
        context.registerBean("eulaService", EulaService::class.java, Supplier { eulaService })
        context.registerBean("logger", Logger::class.java, Supplier { logger })
        context.registerBean("processLauncher", ServerProcessLauncher::class.java, Supplier { launcher })
        context.registerBean("startManifestStore", InstanceStartManifestStore::class.java, Supplier { startManifestStore })
        context.register(ProcessManagerService::class.java)
        context.refresh()
        service = context.getBean(ProcessManagerService::class.java)
        service.startInstance(id)

        context.close()

        assertEquals("stop\n", process.commands())
        assertFalse(process.alive.get())
        assertThrows<IllegalStateException> { service.startInstance(UUID.randomUUID()) }
    }

    @Test
    fun `context closing rejects a start still preparing before it can spawn`() {
        val process = FakeProcess()
        val id = prepare(process)
        val preparing = CountDownLatch(1)
        val release = CountDownLatch(1)
        every { eulaService.isEulaAccepted(id) } answers {
            preparing.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            true
        }
        val start = testThreads.submit { service.startInstance(id) }
        try {
            assertTrue(preparing.await(2, TimeUnit.SECONDS))
            service.rejectStartsOnContextClose()
        } finally {
            release.countDown()
        }

        assertInstanceOf(IllegalStateException::class.java, assertThrows<ExecutionException> {
            start.get(2, TimeUnit.SECONDS)
        }.cause)
        service.shutdown()
        verify(exactly = 0) { launcher.start(any(), any()) }
    }

    @Test
    fun `a concurrent start cannot replace an in-flight launch`() {
        val process = FakeProcess()
        val id = prepare(process)
        val launching = CountDownLatch(1)
        val release = CountDownLatch(1)
        every { launcher.start(any(), directory) } answers {
            launching.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            process
        }
        val start = testThreads.submit { service.startInstance(id) }
        try {
            assertTrue(launching.await(2, TimeUnit.SECONDS))
            assertThrows<IllegalStateException> { service.startInstance(id) }
        } finally {
            release.countDown()
        }
        start.get(2, TimeUnit.SECONDS)
        service.shutdown()
        verify(exactly = 1) { launcher.start(any(), directory) }
    }

    @Test
    fun `shutdown includes a process whose native launch is already in flight`() {
        val process = FakeProcess()
        val id = prepare(process)
        val launching = CountDownLatch(1)
        val release = CountDownLatch(1)
        every { launcher.start(any(), directory) } answers {
            launching.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            process
        }
        val start = testThreads.submit { service.startInstance(id) }
        try {
            assertTrue(launching.await(2, TimeUnit.SECONDS))
            service.rejectStartsOnContextClose()
            val shutdown = testThreads.submit { service.shutdown() }
            assertFalse(shutdown.isDone)
            release.countDown()
            shutdown.get(2, TimeUnit.SECONDS)
            start.get(2, TimeUnit.SECONDS)
        } finally {
            release.countDown()
        }

        assertEquals("stop\n", process.commands())
        assertFalse(process.alive.get())
        assertEquals(0, process.forceKills.get())
    }

    @Test
    fun `a launch exceeding the shutdown budget is a failure and still receives stop when it returns`() {
        service = newService(150)
        val stopSent = CountDownLatch(1)
        val process = FakeProcess(output = object : ByteArrayOutputStream() {
            override fun flush() {
                stopSent.countDown()
            }
        })
        val id = prepare(process)
        val launching = CountDownLatch(1)
        val release = CountDownLatch(1)
        every { launcher.start(any(), directory) } answers {
            launching.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            process
        }
        val start = testThreads.submit { service.startInstance(id) }
        try {
            assertTrue(launching.await(2, TimeUnit.SECONDS))
            val error = assertThrows<IllegalStateException> { service.shutdown() }
            assertTrue(error.message!!.contains(id.toString()))
            assertTrue(error.message!!.contains("incomplete"))
        } finally {
            release.countDown()
        }
        start.get(2, TimeUnit.SECONDS)

        assertTrue(stopSent.await(2, TimeUnit.SECONDS))
        assertEquals("stop\n", process.commands())
        assertEquals(0, process.forceKills.get())
        assertThrows<IllegalStateException> { service.shutdown() }
        verify(exactly = 0) { logger.info(match { it.contains("shutdown complete:") }) }
    }

    @Test
    fun `failed context-close stop attempts remain failures after the parent has already exited`() {
        for (exitCode in listOf(0, 17)) {
            service = newService()
            val attempted = CountDownLatch(1)
            lateinit var process: FakeProcess
            process = FakeProcess(
                output = object : OutputStream() {
                    override fun write(value: Int) {
                        process.alive.set(false)
                        attempted.countDown()
                        throw IOException("provider-key=do-not-log-this")
                    }
                },
                exitCode = exitCode
            )
            val id = prepare(process)
            every { launcher.start(any(), directory) } answers {
                service.rejectStartsOnContextClose()
                process
            }

            service.startInstance(id)
            assertTrue(attempted.await(2, TimeUnit.SECONDS))
            val error = assertThrows<IllegalStateException> { service.shutdown() }

            assertTrue(error.message!!.contains(id.toString()))
            assertFalse(error.message!!.contains("provider-key=do-not-log-this"))
            assertEquals(0, process.forceKills.get())
            assertEquals(0, process.terminations.get())
        }
        verify(exactly = 0) { logger.info(match { it.contains("shutdown complete:") }) }
    }

    @Test
    fun `successful context-close stop delivery still verifies a nonzero exit before the destroy hook`() {
        val exited = CountDownLatch(1)
        lateinit var process: FakeProcess
        process = FakeProcess(
            output = object : ByteArrayOutputStream() {
                override fun flush() {
                    process.alive.set(false)
                    exited.countDown()
                }
            },
            exitCode = 17
        )
        val id = prepare(process)
        every { launcher.start(any(), directory) } answers {
            service.rejectStartsOnContextClose()
            process
        }

        service.startInstance(id)
        assertTrue(exited.await(2, TimeUnit.SECONDS))
        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(error.message!!.contains("code 17"))
        assertEquals("stop\n", process.commands())
        verify(exactly = 0) { logger.info(match { it.contains("shutdown complete:") }) }
    }

    @Test
    fun `successful context-close stop and zero exit before the destroy hook remain successful`() {
        val exited = CountDownLatch(1)
        lateinit var process: FakeProcess
        process = FakeProcess(output = object : ByteArrayOutputStream() {
            override fun flush() {
                process.alive.set(false)
                exited.countDown()
            }
        })
        val id = prepare(process)
        every { launcher.start(any(), directory) } answers {
            service.rejectStartsOnContextClose()
            process
        }

        service.startInstance(id)
        assertTrue(exited.await(2, TimeUnit.SECONDS))
        service.shutdown()

        assertEquals("stop\n", process.commands())
        assertEquals(0, process.forceKills.get())
    }

    @Test
    fun `a server active at context close remains tracked if it crashes before the destroy hook`() {
        val process = FakeProcess(exitCode = 17)
        val id = start(process)
        service.rejectStartsOnContextClose()
        process.alive.set(false)

        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(error.message!!.contains(id.toString()))
        assertTrue(error.message!!.contains("code 17"))
        assertEquals(0, process.forceKills.get())
        verify(exactly = 0) { logger.info(match { it.contains("shutdown complete:") }) }
    }

    @Test
    fun `a late launch with blocked shutdown stdin never blocks its start caller or hides shutdown failure`() {
        service = newService(100)
        val writing = CountDownLatch(1)
        val release = CountDownLatch(1)
        val writerFinished = CountDownLatch(1)
        val attempts = AtomicInteger()
        val process = FakeProcess(output = object : OutputStream() {
            override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)
            override fun write(buffer: ByteArray, offset: Int, length: Int) {
                attempts.incrementAndGet()
                writing.countDown()
                try {
                    release.await()
                    throw IOException("token=do-not-log-this")
                } finally {
                    writerFinished.countDown()
                }
            }
        }).apply { onWait = { _, _ -> false } }
        val id = prepare(process)
        every { launcher.start(any(), directory) } answers {
            service.rejectStartsOnContextClose()
            process
        }
        val start = testThreads.submit { service.startInstance(id) }
        try {
            start.get(500, TimeUnit.MILLISECONDS)
            assertTrue(writing.await(2, TimeUnit.SECONDS))
            val shutdown = testThreads.submit { service.shutdown() }
            val error = assertThrows<ExecutionException> { shutdown.get(1, TimeUnit.SECONDS) }
            assertInstanceOf(IllegalStateException::class.java, error.cause)
            assertTrue(error.cause!!.message!!.contains(id.toString()))
            assertFalse(error.cause!!.message!!.contains("token=do-not-log-this"))
        } finally {
            release.countDown()
        }

        assertTrue(writerFinished.await(2, TimeUnit.SECONDS))
        assertEquals(1, attempts.get())
        assertTrue(process.alive.get())
        assertEquals(0, process.forceKills.get())
        assertEquals(0, process.terminations.get())
        verify(exactly = 0) { logger.info(match { it.contains("shutdown complete:") }) }
    }

    @Test
    fun `a failed launch releases its reservation and shutdown does not wait for a nonexistent process`() {
        val process = FakeProcess()
        val id = prepare(process)
        every { launcher.start(any(), directory) } throws IOException("launch failed")
        assertThrows<IOException> { service.startInstance(id) }
        every { launcher.start(any(), directory) } returns process

        service.startInstance(id)
        service.shutdown()

        assertEquals("stop\n", process.commands())
        assertFalse(process.alive.get())
    }

    @Test
    fun `stop write failure is actionable redacted and does not prevent other servers stopping`() {
        val secret = "provider-key=do-not-log-this"
        val broken = FakeProcess(output = object : OutputStream() {
            override fun write(value: Int) = throw IOException(secret)
        })
        val brokenId = start(broken)
        val healthy = FakeProcess()
        start(healthy)

        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(error.message!!.contains(brokenId.toString()))
        assertTrue(error.message!!.contains("world saving not confirmed"))
        assertTrue(error.message!!.contains("before restarting Moddex"))
        assertFalse(error.message!!.contains(secret))
        verify(exactly = 0) { logger.error(match { it.contains(secret) }) }
        assertEquals("stop\n", healthy.commands())
        assertFalse(healthy.alive.get())
        assertEquals(0, broken.forceKills.get())
    }

    @Test
    fun `a blocked console does not hold shutdown indefinitely or block other stop commands`() {
        service = newService(150)
        val writing = CountDownLatch(1)
        val release = CountDownLatch(1)
        val writerFinished = CountDownLatch(1)
        val blocked = FakeProcess(output = object : OutputStream() {
            override fun write(value: Int) {
                writing.countDown()
                try {
                    release.await()
                } finally {
                    writerFinished.countDown()
                }
            }
        })
        blocked.onWait = { _, _ -> false }
        val blockedId = start(blocked)
        val healthy = FakeProcess()
        start(healthy)
        val before = System.nanoTime()
        try {
            val error = assertThrows<IllegalStateException> { service.shutdown() }
            assertTrue(writing.await(1, TimeUnit.SECONDS))
            assertTrue(error.message!!.contains(blockedId.toString()))
            assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - before) < 1_000)
        } finally {
            release.countDown()
        }

        assertTrue(writerFinished.await(1, TimeUnit.SECONDS))
        assertEquals("stop\n", healthy.commands())
        assertFalse(healthy.alive.get())
        assertTrue(blocked.alive.get())
        assertEquals(0, blocked.forceKills.get())
    }

    @Test
    fun `stop commands are dispatched to all servers before waiting for a slow exit`() {
        val allWaiting = CountDownLatch(3)
        val processes = List(3) {
            FakeProcess().apply {
                onWait = { timeout, unit ->
                    allWaiting.countDown()
                    assertTrue(allWaiting.await(timeout, unit))
                    alive.set(false)
                    true
                }
            }
        }
        processes.forEach { start(it) }

        service.shutdown()

        processes.forEach { assertEquals("stop\n", it.commands()) }
    }

    @Test
    fun `waiting for a normal console command lock also respects the shutdown deadline`() {
        service = newService(150)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val stopWritten = CountDownLatch(1)
        val firstWrite = AtomicBoolean(true)
        val bytes = ByteArrayOutputStream()
        val process = FakeProcess(output = object : OutputStream() {
            override fun write(value: Int) = bytes.write(value)
            override fun write(buffer: ByteArray, offset: Int, length: Int) {
                if (firstWrite.compareAndSet(true, false)) {
                    entered.countDown()
                    release.await()
                }
                bytes.write(buffer, offset, length)
                if (bytes.toString().contains("stop\n")) stopWritten.countDown()
            }
        }).apply { onWait = { _, _ -> false } }
        val id = start(process)
        val command = testThreads.submit { service.sendCommand(id, "save-all") }
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            val error = assertThrows<IllegalStateException> { service.shutdown() }
            assertTrue(error.message!!.contains(id.toString()))
        } finally {
            release.countDown()
        }

        command.get(2, TimeUnit.SECONDS)
        assertTrue(stopWritten.await(2, TimeUnit.SECONDS))
        assertEquals("save-all\nstop\n", bytes.toString())
        assertEquals(0, process.forceKills.get())
    }

    @Test
    fun `console delivery consumes the same budget as waiting for process exit`() {
        val process = FakeProcess(output = object : ByteArrayOutputStream() {
            override fun flush() {
                Thread.sleep(150)
            }
        })
        service = newService(1_000)
        start(process)

        service.shutdown()

        assertEquals(1, process.waits.size)
        assertTrue(process.waits.single() <= TimeUnit.MILLISECONDS.toNanos(900))
    }

    @Test
    fun `one shared deadline bounds multiple processes that refuse to exit`() {
        service = newService(150)
        val processes = List(3) {
            FakeProcess().apply {
                onWait = { timeout, unit ->
                    TimeUnit.NANOSECONDS.sleep(unit.toNanos(timeout))
                    false
                }
            }
        }
        val ids = processes.map { start(it) }
        val before = System.nanoTime()

        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - before) < 1_000)
        ids.forEach { assertTrue(error.message!!.contains(it.toString())) }
        processes.forEach {
            assertEquals("stop\n", it.commands())
            assertTrue(it.alive.get())
            assertEquals(0, it.forceKills.get())
            assertEquals(0, it.terminations.get())
        }
    }

    @Test
    fun `a process still alive after wait is never reported as successfully stopped`() {
        val process = FakeProcess().apply { onWait = { _, _ -> true } }
        start(process)

        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(error.message!!.contains("still running"))
        assertTrue(process.alive.get())
        assertEquals(0, process.forceKills.get())
    }

    @Test
    fun `interruption is restored and incomplete termination is reported without killing servers`() {
        val waiting = CountDownLatch(1)
        val process = FakeProcess().apply {
            onWait = { _, _ ->
                waiting.countDown()
                CountDownLatch(1).await()
                false
            }
        }
        start(process)
        val failure = AtomicReference<Throwable>()
        val interruptRestored = AtomicBoolean(false)
        val shutdownThread = thread(isDaemon = true, name = "Interrupted-Shutdown-Test") {
            try {
                service.shutdown()
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                interruptRestored.set(Thread.currentThread().isInterrupted)
            }
        }
        assertTrue(waiting.await(2, TimeUnit.SECONDS))

        shutdownThread.interrupt()
        shutdownThread.join(2_000)

        assertFalse(shutdownThread.isAlive)
        assertInstanceOf(IllegalStateException::class.java, failure.get())
        assertTrue(failure.get().message!!.contains("interrupted"))
        assertTrue(interruptRestored.get())
        assertTrue(process.alive.get())
        assertEquals(0, process.forceKills.get())
    }

    @Test
    fun `a nonzero exit is a failure even after the process has terminated`() {
        val process = FakeProcess(exitCode = 42)
        start(process)

        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(error.message!!.contains("code 42"))
        assertTrue(error.message!!.contains("verify world saving"))
        assertFalse(process.alive.get())
    }

    @Test
    fun `wait failures do not expose exception contents or prevent other servers stopping`() {
        val secret = "password=do-not-log-this"
        val broken = FakeProcess().apply { onWait = { _, _ -> throw IOException(secret) } }
        val id = start(broken)
        val healthy = FakeProcess()
        start(healthy)

        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(error.message!!.contains(id.toString()))
        assertTrue(error.message!!.contains("before restarting Moddex"))
        assertFalse(error.message!!.contains(secret))
        verify(exactly = 0) { logger.error(match { it.contains(secret) }) }
        assertFalse(healthy.alive.get())
        assertEquals(0, broken.forceKills.get())
    }

    @Test
    fun `a surviving child process prevents success even when the managed JVM exits`() {
        service = newService(150)
        val child = mockk<ProcessHandle>()
        every { child.pid() } returns 1234
        every { child.isAlive } returns true
        every { child.onExit() } returns CompletableFuture()
        val process = FakeProcess(children = listOf(child))
        val id = start(process)

        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(error.message!!.contains(id.toString()))
        assertFalse(process.alive.get())
        verify(exactly = 0) { child.destroy() }
        verify(exactly = 0) { child.destroyForcibly() }
        verify(exactly = 0) { logger.info(match { it.contains("shutdown complete:") }) }
    }

    @Test
    fun `children observed during normal stop remain tracked after their parent exits`() {
        service = newService(150)
        val child = mockk<ProcessHandle>()
        every { child.pid() } returns 1234
        every { child.isAlive } returns true
        every { child.onExit() } returns CompletableFuture()
        val process = FakeProcess(children = listOf(child))
        val id = start(process)
        service.stopInstance(id)
        process.alive.set(false)

        assertThrows<IllegalStateException> { service.startInstance(id) }
        assertThrows<IllegalStateException> { service.shutdown() }
    }

    @Test
    fun `a child appearing while stop is delivered must also terminate`() {
        service = newService(150)
        val child = mockk<ProcessHandle>()
        every { child.pid() } returns 1234
        every { child.isAlive } returns true
        every { child.onExit() } returns CompletableFuture()
        val children = mutableListOf<ProcessHandle>()
        val process = FakeProcess(
            output = object : ByteArrayOutputStream() {
                override fun flush() {
                    children.add(child)
                }
            },
            children = children
        )
        start(process)

        assertThrows<IllegalStateException> { service.shutdown() }

        assertFalse(process.alive.get())
        verify(exactly = 0) { child.destroyForcibly() }
    }

    @Test
    fun `children that exit with the server permit successful shutdown`() {
        val childAlive = AtomicBoolean(true)
        val child = mockk<ProcessHandle>()
        every { child.pid() } returns 1234
        every { child.isAlive } answers { childAlive.get() }
        val process = FakeProcess(children = listOf(child)).apply {
            onWait = { _, _ ->
                alive.set(false)
                childAlive.set(false)
                true
            }
        }
        start(process)

        service.shutdown()

        assertFalse(childAlive.get())
        assertEquals(0, process.forceKills.get())
    }

    @Test
    fun `failure to inspect children is redacted but still attempts orderly stop`() {
        val process = FakeProcess().apply { descendantFailure = IllegalStateException("token=secret") }
        start(process)

        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertEquals("stop\n", process.commands())
        assertFalse(error.message!!.contains("token=secret"))
        assertTrue(error.message!!.contains("could not inspect child processes"))
        assertFalse(process.alive.get())
    }

    @Test
    fun `failed child inspection during normal stop is not forgotten when the parent later exits`() {
        val process = FakeProcess().apply { descendantFailure = IllegalStateException("token=secret") }
        val id = start(process)
        service.stopInstance(id)
        process.alive.set(false)

        assertThrows<IllegalStateException> { service.startInstance(id) }
        val error = assertThrows<IllegalStateException> { service.shutdown() }

        assertTrue(error.message!!.contains("could not inspect child processes"))
        assertFalse(error.message!!.contains("token=secret"))
    }

    @Test
    fun `nonpositive timeout configuration is rejected`() {
        assertThrows<IllegalArgumentException> { newService(0) }
        assertThrows<IllegalArgumentException> { newService(-1) }
    }

    @Test
    fun `bundled systemd unit signals the backend first and never force kills a slow world save`() {
        val unit = Files.readString(Path.of("..", "packaging", "systemd", "moddex-backend.service"))
        val directives = unit.lineSequence()
            .filter { it.isNotBlank() && !it.startsWith("#") && '=' in it }
            .associate { it.substringBefore('=') to it.substringAfter('=') }

        assertEquals("mixed", directives["KillMode"])
        assertEquals("no", directives["SendSIGKILL"])
        assertEquals("120s", directives["TimeoutStopSec"])
    }

    private fun newService(timeoutMillis: Long = 2_000) =
        ProcessManagerService(instanceService, eulaService, logger, launcher, timeoutMillis, startManifestStore)

    private fun prepare(process: FakeProcess, id: UUID = UUID.randomUUID()): UUID {
        every { eulaService.isEulaAccepted(id) } returns true
        every { instanceService.getInstanceById(id) } returns Instance(id = id, name = "Test")
        every { instanceService.getInstancePath(id) } returns directory
        every { launcher.start(any(), directory) } returns process
        return id
    }

    /** Mirrors the Maven layout a modern Forge/NeoForge `--installServer` run leaves behind. */
    private fun installLoaderArgs(loaderArtifactPath: String, version: String): String {
        val versionDir = directory.resolve("libraries").resolve(loaderArtifactPath).resolve(version)
        Files.createDirectories(versionDir)
        Files.createFile(versionDir.resolve("win_args.txt"))
        Files.createFile(versionDir.resolve("unix_args.txt"))
        val userJvmArgs = directory.resolve("user_jvm_args.txt")
        if (Files.notExists(userJvmArgs)) {
            Files.createFile(userJvmArgs)
        }
        return "@libraries/$loaderArtifactPath/$version/" +
            ProcessManagerService.preferredArgsFileName(System.getProperty("os.name"))
    }

    private fun start(process: FakeProcess): UUID =
        prepare(process).also { service.startInstance(it) }

    private class FakeProcess(
        private val output: OutputStream = ByteArrayOutputStream(),
        private val exitCode: Int = 0,
        private val children: List<ProcessHandle> = emptyList()
    ) : Process() {
        val alive = AtomicBoolean(true)
        val forceKills = AtomicInteger()
        val terminations = AtomicInteger()
        val waits = java.util.concurrent.CopyOnWriteArrayList<Long>()
        var onWait: ((Long, TimeUnit) -> Boolean)? = null
        var descendantFailure: RuntimeException? = null

        override fun getOutputStream() = output
        override fun getInputStream() = ByteArrayInputStream(byteArrayOf())
        override fun getErrorStream() = ByteArrayInputStream(byteArrayOf())
        override fun isAlive() = alive.get()
        override fun pid() = 5678L
        override fun descendants(): Stream<ProcessHandle> {
            descendantFailure?.let { throw it }
            return children.stream()
        }

        override fun waitFor(): Int = error("Unbounded wait must not be used")
        override fun waitFor(timeout: Long, unit: TimeUnit): Boolean {
            waits.add(unit.toNanos(timeout))
            return onWait?.invoke(timeout, unit) ?: run {
                alive.set(false)
                true
            }
        }

        override fun exitValue(): Int {
            check(!alive.get()) { "Process is still alive" }
            return exitCode
        }

        override fun destroy() {
            terminations.incrementAndGet()
            alive.set(false)
        }

        override fun destroyForcibly(): Process {
            forceKills.incrementAndGet()
            alive.set(false)
            return this
        }

        fun commands(): String = output.toString()
    }
}

package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.model.mods.InstanceModList
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.runs
import io.mockk.unmockkStatic
import io.mockk.verify
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.condition.EnabledOnOs
import org.junit.jupiter.api.condition.OS
import org.junit.jupiter.api.io.TempDir
import org.springframework.http.HttpStatus
import org.springframework.web.server.ResponseStatusException
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class InstanceServiceTest {

    @TempDir
    lateinit var tempDir: Path

    private lateinit var directories: ModdexDirectories
    private lateinit var serverSettingsService: ServerSettingsService
    private lateinit var instanceInstallerService: InstanceInstallerService
    private lateinit var modListStore: InstanceModListStore
    private lateinit var logger: Logger
    private lateinit var service: InstanceService

    @BeforeEach
    fun setUp() {
        directories = object : ModdexDirectories {
            override val configDir: Path = tempDir.resolve("config")
            override val dataDir: Path = tempDir.resolve("data")
            override val logsDir: Path = tempDir.resolve("logs")
        }

        serverSettingsService = mockk()
        instanceInstallerService = mockk()
        modListStore = mockk()
        logger = mockk(relaxed = true)

        val serverSettings = ServerSettings().apply {
            projectPath = directories.dataDir.toString()
            defaultJavaXmx = "4G"
            defaultJavaXms = "2G"
        }

        every { serverSettingsService.getServerSettings() } returns serverSettings
        every { modListStore.ensure(any(), any()) } answers { InstanceModList(instanceId = secondArg()) }
        every { instanceInstallerService.downloadInstaller(any(), any()) } just runs

        service = InstanceService(
            serverSettingsService,
            jacksonObjectMapper(),
            instanceInstallerService,
            modListStore,
            logger,
            directories,
        )
    }

    @Test
    fun createAndInstallInstancePersistsConfigurationAndInvokesInstaller() {
        val request = Instance(name = "Test Instance", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)

        val created = service.createAndInstallInstance(request)

        assertThat(created.id).isNotNull()
        val instanceDir = directories.dataDir.resolve("instances").resolve("Test_Instance")
        assertThat(Files.exists(instanceDir)).isTrue()
        val stored = jacksonObjectMapper().readValue(instanceDir.resolve("instance.json").toFile(), Instance::class.java)
        assertThat(stored.id).isEqualTo(created.id)
        assertThat(stored.javaXmx).isEqualTo("4G")
        assertThat(stored.javaXms).isEqualTo("2G")

        verify { modListStore.ensure(instanceDir, created.id!!) }
        verify { instanceInstallerService.downloadInstaller(match { it.id == created.id }, instanceDir) }
    }

    @Test
    fun createAndInstallInstanceOverwritesClientSuppliedIdWithServerGeneratedId() {
        val supplied = UUID.randomUUID()

        val created = service.createAndInstallInstance(
            Instance(id = supplied, name = "Supplied", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        )

        // The identity comes from the server; the client value is never adopted.
        assertThat(created.id).isNotNull().isNotEqualTo(supplied)
        val stored = jacksonObjectMapper().readValue(
            directories.dataDir.resolve("instances").resolve("Supplied").resolve("instance.json").toFile(),
            Instance::class.java,
        )
        assertThat(stored.id).isEqualTo(created.id)
    }

    @Test
    fun createAndInstallInstanceIgnoresClientSuppliedExistingIdAndKeepsExistingData() {
        val existing = service.createAndInstallInstance(
            Instance(name = "Original", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        )
        val existingId = existing.id!!
        val existingConfig = directories.dataDir.resolve("instances").resolve("Original").resolve("instance.json")
        val before = Files.readAllBytes(existingConfig)

        val duplicate = service.createAndInstallInstance(
            Instance(id = existingId, name = "Duplicate", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        )

        // The duplicate gets its own identity and its own directory; the
        // existing instance's persisted data stays byte-for-byte unchanged.
        assertThat(duplicate.id).isNotNull().isNotEqualTo(existingId)
        assertThat(Files.readAllBytes(existingConfig)).isEqualTo(before)
        val storedExisting = jacksonObjectMapper().readValue(existingConfig.toFile(), Instance::class.java)
        assertThat(storedExisting.id).isEqualTo(existingId)
        assertThat(storedExisting.name).isEqualTo("Original")
        val storedDuplicate = jacksonObjectMapper().readValue(
            directories.dataDir.resolve("instances").resolve("Duplicate").resolve("instance.json").toFile(),
            Instance::class.java,
        )
        assertThat(storedDuplicate.id).isEqualTo(duplicate.id)
        assertThat(service.getInstanceById(existingId).name).isEqualTo("Original")
        assertThat(service.getInstanceById(duplicate.id!!).name).isEqualTo("Duplicate")
    }

    @Test
    fun generatedInstanceIdAvoidsIdsAlreadyInUse() {
        val takenId = service.createAndInstallInstance(
            Instance(name = "Taken", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        ).id!!
        val freshId = UUID.randomUUID()
        // Scripted draws: the first candidate collides with the persisted id and
        // must be redrawn; fallback entries keep unrelated callers (if any) working.
        val scripted = ArrayDeque(listOf(takenId, freshId))
        repeat(16) { scripted.add(UUID.randomUUID()) }
        mockkStatic(UUID::class)
        try {
            every { UUID.randomUUID() } answers { scripted.removeFirst() }

            val created = service.createAndInstallInstance(
                Instance(name = "Collision", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
            )

            assertThat(created.id).isEqualTo(freshId).isNotEqualTo(takenId)
        } finally {
            unmockkStatic(UUID::class)
        }
        val stored = jacksonObjectMapper().readValue(
            directories.dataDir.resolve("instances").resolve("Collision").resolve("instance.json").toFile(),
            Instance::class.java,
        )
        assertThat(stored.id).isEqualTo(freshId)
    }

    @Test
    fun concurrentCreatesReceiveDistinctIdsAndSeparateDirectories() {
        val threadCount = 4
        val startBarrier = CyclicBarrier(threadCount)
        val executor = Executors.newFixedThreadPool(threadCount)
        try {
            val futures = (1..threadCount).map {
                executor.submit<Instance> {
                    startBarrier.await(10, TimeUnit.SECONDS)
                    service.createAndInstallInstance(
                        Instance(name = "Parallel", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
                    )
                }
            }
            val created = futures.map { it.get(30, TimeUnit.SECONDS) }

            val ids = created.map { it.id!! }
            assertThat(ids.distinct()).hasSameSizeAs(ids)

            // The atomic directory reservation keeps every creation in its own
            // directory even though all four used the same name.
            val resolvedDirs = ids.map { id -> service.getInstancePath(id) }
            assertThat(resolvedDirs.distinct()).hasSameSizeAs(resolvedDirs)
            resolvedDirs.forEachIndexed { index, dir ->
                val stored = jacksonObjectMapper().readValue(dir.resolve("instance.json").toFile(), Instance::class.java)
                assertThat(stored.id).isEqualTo(ids[index])
            }
            val instanceRoot = directories.dataDir.resolve("instances")
            val directoryCount = Files.list(instanceRoot).use { stream ->
                stream.filter { Files.isDirectory(it) }.count()
            }
            assertThat(directoryCount).isEqualTo(threadCount.toLong())
        } finally {
            executor.shutdownNow()
            assertThat(executor.awaitTermination(10, TimeUnit.SECONDS)).isTrue()
        }
    }

    @Test
    fun deleteInstanceByIdRemovesInstanceDirectory() {
        val request = Instance(name = "Delete Me", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        val created = service.createAndInstallInstance(request)
        val instanceDir = directories.dataDir.resolve("instances").resolve("Delete_Me")
        assertThat(Files.exists(instanceDir)).isTrue()

        service.deleteInstanceById(created.id!!)

        assertThat(Files.exists(instanceDir)).isFalse()
    }

    @Test
    @EnabledOnOs(OS.WINDOWS)
    fun deleteInstanceByIdReportsRemainingFilesWhenAFileIsLockedOnWindows() {
        val created = service.createAndInstallInstance(Instance(name = "Locked", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA))
        val instanceDir = directories.dataDir.resolve("instances").resolve("Locked")
        val instanceJson = instanceDir.resolve("instance.json")

        // An open handle without share-delete keeps the file undeletable on Windows.
        RandomAccessFile(instanceJson.toFile(), "rw").use {
            val exception = assertThrows<InstanceDeletionException> {
                service.deleteInstanceById(created.id!!)
            }

            assertThat(exception.remainingPaths).contains("instance.json")
            assertThat(Files.exists(instanceJson)).isTrue()
        }
        verify(exactly = 0) { logger.info(match<String> { it.contains("deleted (path") }) }
    }

    @Test
    @EnabledOnOs(OS.LINUX)
    fun deleteInstanceByIdReportsRemainingFilesWhenDirectoryIsNotWritableOnPosix() {
        // CI containers run as root, and root bypasses directory permission
        // checks; only run when the filesystem actually enforces the denial.
        assumePosixDenialIsEnforced()
        val created = service.createAndInstallInstance(Instance(name = "Locked", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA))
        val instanceDir = directories.dataDir.resolve("instances").resolve("Locked")
        val worlds = instanceDir.resolve("worlds")
        Files.createDirectory(worlds)
        Files.write(worlds.resolve("level.dat"), byteArrayOf(1))
        Files.setPosixFilePermissions(worlds, PosixFilePermissions.fromString("r-xr-xr-x"))
        try {
            val exception = assertThrows<InstanceDeletionException> {
                service.deleteInstanceById(created.id!!)
            }

            assertThat(exception.remainingPaths).contains("worlds/level.dat", "worlds")
            assertThat(Files.exists(worlds.resolve("level.dat"))).isTrue()
        } finally {
            Files.setPosixFilePermissions(worlds, PosixFilePermissions.fromString("rwxr-xr-x"))
        }
        verify(exactly = 0) { logger.info(match<String> { it.contains("deleted (path") }) }
    }

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
        } catch (_: java.nio.file.AccessDeniedException) {
            // Enforced as expected; the POSIX error path can be exercised.
        } finally {
            Files.setPosixFilePermissions(probe, PosixFilePermissions.fromString("rwxr-xr-x"))
            Files.deleteIfExists(child)
            Files.deleteIfExists(probe)
        }
    }

    @Test
    fun getInstanceByIdReturnsPersistedInstance() {
        val request = Instance(name = "Lookup", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        val created = service.createAndInstallInstance(request)

        val loaded = service.getInstanceById(created.id!!)

        assertThat(loaded.name).isEqualTo("Lookup")
        assertThat(loaded.id).isEqualTo(created.id)
    }

    @Test
    fun getInstancePathThrowsWhenInstanceMissing() {
        val missing = UUID.fromString("11111111-1111-1111-1111-111111111111")

        val exception = org.junit.jupiter.api.assertThrows<org.springframework.web.server.ResponseStatusException> {
            service.getInstancePath(missing)
        }

        assertThat(exception.statusCode.value()).isEqualTo(404)
    }

    // ---- Rollback of a failed creation (#257) ----

    @Test
    fun failedDownloadRollsBackTheReservedDirectoryAndPreservesADiagnosisRecord() {
        val request = Instance(name = "Failed Download", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        every { instanceInstallerService.downloadInstaller(any(), any()) } throws ResponseStatusException(
            HttpStatus.BAD_GATEWAY,
            "The vanilla server jar download was rejected because the artifact host answered with HTTP 500. " +
                "Start the installation again; if it keeps failing, check the provider's availability",
        )

        val failure = assertThrows<ResponseStatusException> { service.createAndInstallInstance(request) }

        // No seemingly ready instance remains behind.
        val instanceDir = directories.dataDir.resolve("instances").resolve("Failed_Download")
        assertThat(Files.exists(instanceDir)).isFalse()
        assertThat(service.getAllInstances()).isEmpty()
        assertThat(
            assertThrows<ResponseStatusException> { service.getInstanceById(request.id!!) }.statusCode.value(),
        ).isEqualTo(404)

        // The diagnosable job data is preserved separately from the instances.
        val record = readSingleCreationFailureRecord(request.id!!)
        assertThat(record.instanceId).isEqualTo(request.id)
        assertThat(record.instanceName).isEqualTo("Failed Download")
        assertThat(record.phase).isEqualTo("download and installation")
        assertThat(record.errorKind).isEqualTo("ResponseStatusException")
        assertThat(record.detail).contains("answered with HTTP 500")

        // The guided failure wording stays and names the rollback and the record.
        assertThat(failure.statusCode).isEqualTo(HttpStatus.BAD_GATEWAY)
        assertThat(failure.reason).contains("answered with HTTP 500")
        assertThat(failure.reason).contains("was removed")
        assertThat(failure.reason).contains(InstanceService.CREATION_FAILURE_RECORDS_DIR)
        assertThat(failure.cause).isNull()
    }

    @Test
    fun failedInstallerRunRollsBackTheReservedDirectoryAndPreservesADiagnosisRecord() {
        val request = Instance(
            name = "Failed Install",
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "47.1.0",
        )
        every { instanceInstallerService.downloadInstaller(any(), any()) } throws ResponseStatusException(
            HttpStatus.INTERNAL_SERVER_ERROR,
            "Installer exited with code 7. Check the installer output and the instance Java version, then retry.",
        )

        val failure = assertThrows<ResponseStatusException> { service.createAndInstallInstance(request) }

        assertThat(Files.exists(directories.dataDir.resolve("instances").resolve("Failed_Install"))).isFalse()
        assertThat(service.getAllInstances()).isEmpty()
        val record = readSingleCreationFailureRecord(request.id!!)
        assertThat(record.instanceName).isEqualTo("Failed Install")
        assertThat(record.phase).isEqualTo("download and installation")
        assertThat(record.detail).contains("exited with code 7")
        assertThat(failure.statusCode).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR)
        assertThat(failure.reason).contains("exited with code 7")
        assertThat(failure.reason).contains("was removed")
        assertThat(failure.reason).contains(InstanceService.CREATION_FAILURE_RECORDS_DIR)
    }

    @Test
    fun rawMetadataFailureBecomesAGuidedRollbackErrorWithoutRawDetails() {
        val request = Instance(name = "Raw Failure", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        every { modListStore.ensure(any(), any()) } throws IOException("raw io detail that must not surface")

        val failure = assertThrows<ResponseStatusException> { service.createAndInstallInstance(request) }

        assertThat(failure.statusCode.value()).isEqualTo(500)
        assertThat(failure.reason).contains("Could not create the instance")
        assertThat(failure.reason).contains("Check")
        assertThat(failure.reason).contains("then retry")
        assertThat(failure.reason).doesNotContain("raw io detail")
        assertThat(failure.cause).isNull()
        assertThat(Files.exists(directories.dataDir.resolve("instances").resolve("Raw_Failure"))).isFalse()
        assertThat(service.getAllInstances()).isEmpty()
        val record = readSingleCreationFailureRecord(request.id!!)
        assertThat(record.phase).isEqualTo("instance metadata")
        assertThat(record.errorKind).isEqualTo("IOException")
        assertThat(record.detail).isNull()
    }

    @Test
    fun creationCanBeRetriedWithTheSameNameAfterARollback() {
        every { instanceInstallerService.downloadInstaller(any(), any()) } throws
            ResponseStatusException(HttpStatus.BAD_GATEWAY, "The provider is temporarily unavailable")
        assertThrows<ResponseStatusException> {
            service.createAndInstallInstance(
                Instance(name = "Retry Me", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
            )
        }
        assertThat(Files.exists(directories.dataDir.resolve("instances").resolve("Retry_Me"))).isFalse()

        // The atomic reservation is freed by the rollback, so the retry uses
        // the plain name again instead of a suffixed directory.
        every { instanceInstallerService.downloadInstaller(any(), any()) } just runs
        val retried = service.createAndInstallInstance(
            Instance(name = "Retry Me", gameVersion = "1.20.4", modLoader = ModLoader.VANILLA)
        )

        val instanceDir = directories.dataDir.resolve("instances").resolve("Retry_Me")
        assertThat(service.getInstancePath(retried.id!!)).isEqualTo(instanceDir)
        assertThat(Files.exists(instanceDir.resolve("instance.json"))).isTrue()
        assertThat(service.getAllInstances()).containsExactly(retried)
    }

    private fun readSingleCreationFailureRecord(instanceId: UUID): InstanceCreationFailureRecord {
        val recordsDir = directories.logsDir.resolve(InstanceService.CREATION_FAILURE_RECORDS_DIR)
        val recordFiles = Files.list(recordsDir).use { stream ->
            stream.map { it.fileName.toString() }.toList()
        }
        assertThat(recordFiles).hasSize(1)
        assertThat(recordFiles.single()).endsWith("-$instanceId.json")
        return jacksonObjectMapper().readValue<InstanceCreationFailureRecord>(
            recordsDir.resolve(recordFiles.single()).toFile(),
        )
    }
}

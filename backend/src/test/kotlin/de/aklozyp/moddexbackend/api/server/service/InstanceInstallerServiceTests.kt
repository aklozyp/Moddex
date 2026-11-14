package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.dto.MojangVersionDetail
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.services.Logger
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.EnumSource
import org.junit.jupiter.params.provider.NullSource
import org.junit.jupiter.params.provider.ValueSource
import org.mockito.Mockito
import org.springframework.http.HttpStatus
import org.springframework.web.server.ResponseStatusException
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID

class InstanceInstallerServiceTests {

    @TempDir
    lateinit var tempDir: Path

    private val logger: Logger = Mockito.mock(Logger::class.java)
    private val serverSettingsService: ServerSettingsService = Mockito.mock(ServerSettingsService::class.java)
    private val objectMapper = jacksonObjectMapper()

    private lateinit var fixture: ArtifactFixtureServer

    @BeforeEach
    fun startFixtureServer() {
        fixture = ArtifactFixtureServer()
        fixture.serve(LOADER_INSTALLER_PATH, LOADER_INSTALLER_BODY)
        fixture.serveSha1Sidecar(LOADER_INSTALLER_PATH, LOADER_INSTALLER_BODY)
        fixture.serve(VANILLA_SERVER_PATH, VANILLA_SERVER_BODY)
        fixture.serveSha1Sidecar(VANILLA_SERVER_PATH, VANILLA_SERVER_BODY)
    }

    @AfterEach
    fun stopFixtureServer() {
        fixture.close()
    }

    private class RecordingProcessRunner(
        var exitCode: Int = 0,
        val failure: Exception? = null,
        val capturedOutput: List<String> = emptyList(),
    ) : InstallerCommandRunner {
        var lastCommand: List<String>? = null
        var lastDirectory: Path? = null
        var lastJobId: String? = null

        override fun run(command: List<String>, workingDirectory: Path, jobId: String): Int {
            lastCommand = command
            lastDirectory = workingDirectory
            lastJobId = jobId
            failure?.let { throw it }
            return exitCode
        }

        override fun recentOutput(jobId: String, maxLines: Int): List<String> {
            if (jobId != lastJobId) return emptyList()
            return capturedOutput.takeLast(minOf(maxLines, capturedOutput.size))
        }
    }

    private fun defaultSettings(): ServerSettings = ServerSettings().apply {
        projectPath = "/tmp"
        defaultJavaXmx = ServerSettingsService.DEFAULT_JAVA_XMX
        defaultJavaXms = ServerSettingsService.DEFAULT_JAVA_XMS
    }

    @ParameterizedTest
    @EnumSource(ModLoader::class)
    fun `uses the selected Java executable as one argument for every loader`(loader: ModLoader) {
        val runner = RecordingProcessRunner()
        val service = serviceWithLocalArtifacts(runner)
        val javaPath = tempDir.resolve("Selected Java 21").resolve("bin").resolve("java").toString()
        val instance = Instance(
            gameVersion = "1.20.1",
            modLoader = loader,
            modLoaderVersion = "test-version",
            javaPath = javaPath
        )

        service.downloadInstaller(instance, tempDir.resolve("instance"))

        if (loader == ModLoader.VANILLA) {
            assertNull(runner.lastCommand, "the vanilla server jar is prepared without an installer run")
            return
        }
        assertEquals(javaPath, runner.lastCommand?.first())
        assertEquals("-Xmx2G", runner.lastCommand?.get(1))
        assertEquals(6, runner.lastCommand?.size)
        assertEquals(
            if (loader == ModLoader.FORGE || loader == ModLoader.NEOFORGE) "--installServer" else "nogui",
            runner.lastCommand?.last()
        )
    }

    @ParameterizedTest
    @NullSource
    @ValueSource(strings = ["", " \t"])
    fun `uses PATH Java only when no executable was selected`(javaPath: String?) {
        val runner = RecordingProcessRunner()
        val service = serviceWithLocalArtifacts(runner)

        val instance = Instance(
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
            javaPath = javaPath
        )
        service.downloadInstaller(instance, tempDir.resolve("instance"))

        assertEquals("java", runner.lastCommand?.first())
    }

    @Test
    fun `an invalid selected Java fails with safe guidance instead of falling back`() {
        val diagnostic = "private native process diagnostic"
        val runner = RecordingProcessRunner(failure = IOException(diagnostic))
        val service = serviceWithLocalArtifacts(runner)
        val javaPath = tempDir.resolve("missing-java").toString()
        val instance = Instance(
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
            javaPath = javaPath
        )

        val error = assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, tempDir.resolve("instance"))
        }

        assertEquals(javaPath, runner.lastCommand?.first())
        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        assertTrue(error.reason!!.contains("Check the instance Java path"))
        assertTrue(error.reason!!.contains("then retry"))
        assertFalse(error.toString().contains(diagnostic))
        assertNull(error.cause)
        Mockito.verify(logger, Mockito.never()).error(Mockito.contains(diagnostic))
    }

    @Test
    fun `an installer failure reports its exit code and next action`() {
        val runner = RecordingProcessRunner(exitCode = 7)
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
            javaPath = "/selected/java"
        )

        val error = assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, tempDir.resolve("instance"))
        }

        assertEquals("/selected/java", runner.lastCommand?.first())
        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        assertTrue(error.reason!!.contains("exited with code 7"))
        assertTrue(error.reason!!.contains("then retry"))
        // The job id identifies the run and appears in the message per AK.
        assertTrue(error.reason!!.contains("(job ${runner.lastJobId})"))
        assertTrue(error.reason!!.contains("(no installer output was captured)"))
    }

    @Test
    fun `an installer failure message contains the job id and a sanitized output excerpt`() {
        val runner = RecordingProcessRunner(
            exitCode = 7,
            capturedOutput = listOf(
                "Downloading https://maven.example.com/file.jar?token=secret-token-1",
                "Extracting to /tmp/secret-credentials/libs",
                "Copying from C:\\Users\\admin\\appdata\\cache",
                "plain failure reason without sensitive content",
            ),
        )
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
            javaPath = "/selected/java"
        )

        val error = assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, tempDir.resolve("instance"))
        }

        val reason = error.reason!!
        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        assertTrue(reason.contains("exited with code 7"))
        assertTrue(reason.contains("job ${runner.lastJobId}"))
        // The harmless line stays readable; paths and URLs are masked.
        assertTrue(reason.contains("plain failure reason without sensitive content"))
        assertTrue(reason.contains("<link removed>"))
        assertTrue(reason.contains("<path removed>"))
        assertFalse(reason.contains("secret-token-1"), "URLs must not leak into the response")
        assertFalse(reason.contains("/tmp/secret-credentials"), "absolute paths must not leak into the response")
        assertFalse(reason.contains("C:\\Users"), "windows paths must not leak into the response")
        assertFalse(reason.contains("maven.example.com"), "the URL must not leak in fragments")
        assertTrue(reason.contains("then retry"))
    }

    @Test
    fun `an installer timeout reports the stopped install with job id, excerpt, and safe next action`() {
        val runner = RecordingProcessRunner(
            failure = InstallerCommandTimeoutException(
                "The installer process timed out after 900000 ms and was terminated."
            ),
            capturedOutput = listOf("resolving dependencies", "downloading library 41"),
        )
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
            javaPath = "/selected/java"
        )

        val error = assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, tempDir.resolve("instance"))
        }

        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        val reason = error.reason!!
        assertTrue(reason.contains("did not finish within the configured time budget"))
        assertTrue(reason.contains("was stopped"))
        assertTrue(reason.contains("job ${runner.lastJobId}"))
        assertTrue(reason.contains("downloading library 41"), "the captured excerpt is retrievable in the message")
        assertTrue(reason.contains("check the backend log"))
        assertTrue(reason.contains("retry"))
        assertFalse(reason.contains("/selected/java"), "the response must not expose raw details")
        assertFalse(reason.contains("timed out after 900000"), "raw exception details stay in the log only")
        assertNull(error.cause)
        Mockito.verify(logger).error(Mockito.contains("Instance id="))
    }

    @Test
    fun `a failing spawn names the job id without exposing raw diagnostics`() {
        val diagnostic = "private native process diagnostic"
        val runner = RecordingProcessRunner(failure = IOException(diagnostic))
        val service = serviceWithLocalArtifacts(runner)
        val javaPath = tempDir.resolve("missing-java").toString()
        val instance = Instance(
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
            javaPath = javaPath
        )

        val error = assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, tempDir.resolve("instance"))
        }

        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        assertTrue(error.reason!!.contains("Could not execute installer (job ${runner.lastJobId})"))
        assertTrue(error.reason!!.contains("Check the instance Java path"))
        assertTrue(error.reason!!.contains("then retry"))
        assertFalse(error.toString().contains(diagnostic))
        assertNull(error.cause)
    }

    private fun serviceWithLocalArtifacts(runner: InstallerCommandRunner): InstanceInstallerService {
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.minecraftServerDownload("1.20.1")).thenReturn(vanillaDownload())
        for (loader in listOf("forge", "neoforge", "fabric", "quilt")) {
            Mockito.`when`(versionService.loaderDownloadUrl(loader, "test-version", "1.20.1"))
                .thenReturn(fixture.url(LOADER_INSTALLER_PATH))
        }
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(defaultSettings())
        return InstanceInstallerService(versionService, serverSettingsService, runner, downloader(), originPolicy(), logger, startManifestStore())
    }

    @Test
    fun `prepares the vanilla server jar under its startable name without an installer run`() {
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.minecraftServerDownload("1.20.4"))
            .thenReturn(artifactDownload("/vanilla-1.20.4.jar", "demo".toByteArray()))
        fixture.serve("/vanilla-1.20.4.jar", "demo".toByteArray())
        fixture.serveSha1Sidecar("/vanilla-1.20.4.jar", "demo".toByteArray())
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(defaultSettings())
        val processRunner = RecordingProcessRunner()

        val service = InstanceInstallerService(versionService, serverSettingsService, processRunner, downloader(), originPolicy(), logger, startManifestStore())
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.4",
            modLoader = ModLoader.VANILLA
        )

        val targetDir = Files.createTempDirectory("instance-vanilla")
        service.downloadInstaller(instance, targetDir)

        // The start path (findServerJar) resolves exactly this name; the jar must
        // not carry the installer name any more.
        val serverJar = targetDir.resolve("server.jar")
        assertTrue(Files.exists(serverJar))
        assertEquals("demo", Files.readString(serverJar))
        assertFalse(
            Files.exists(targetDir.resolve("server-installer.jar")),
            "the vanilla server jar must not be stored under the installer name",
        )

        // Vanilla creation is preparation only: no installer, no game server
        // process inside the creation request; the start stays explicit.
        assertNull(processRunner.lastCommand, "vanilla creation must not start any process")
        assertNull(processRunner.lastDirectory)
    }

    @Test
    fun `stores a start manifest for the vanilla server jar after preparation`() {
        val runner = RecordingProcessRunner()
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(id = UUID.randomUUID(), gameVersion = "1.20.1", modLoader = ModLoader.VANILLA)
        val targetDir = Files.createTempDirectory("instance-vanilla-manifest")

        service.downloadInstaller(instance, targetDir)

        val manifest = objectMapper.readValue<InstanceStartManifest>(
            targetDir.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME).toFile(),
        )
        assertEquals(ModLoader.VANILLA, manifest.loader)
        assertEquals("server.jar", manifest.jarPath)
        assertNull(manifest.argsFile, "a jar contract has no argument file")
        assertTrue(manifest.createdAt!!.isNotBlank())
    }

    @Test
    fun `stores a start manifest referencing the forge argument file after the installer run`() {
        val runner = RecordingProcessRunner()
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
        )
        val targetDir = Files.createTempDirectory("instance-forge-manifest")
        installForgeArgsLayout(targetDir, "1.20.1-47.2.0")

        service.downloadInstaller(instance, targetDir)

        val manifest = objectMapper.readValue<InstanceStartManifest>(
            targetDir.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME).toFile(),
        )
        assertEquals(ModLoader.FORGE, manifest.loader)
        assertEquals(
            "libraries/net/minecraftforge/forge/1.20.1-47.2.0/${ProcessManagerService.preferredArgsFileName(System.getProperty("os.name"))}",
            manifest.argsFile,
            "the argument file is stored relative to the instance directory",
        )
        assertFalse(manifest.argsFile!!.startsWith("/"), "the manifest must not store absolute paths")
        assertNull(manifest.jarPath, "an argument-file contract has no startable jar")
    }

    @Test
    fun `stores a start manifest referencing the fabric launch jar when the installer wrote it`() {
        val runner = RecordingProcessRunner()
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.1",
            modLoader = ModLoader.FABRIC,
            modLoaderVersion = "test-version",
        )
        val targetDir = Files.createTempDirectory("instance-fabric-manifest")
        Files.createFile(targetDir.resolve("fabric-server-launch.jar"))

        service.downloadInstaller(instance, targetDir)

        val manifest = objectMapper.readValue<InstanceStartManifest>(
            targetDir.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME).toFile(),
        )
        assertEquals(ModLoader.FABRIC, manifest.loader)
        assertEquals("fabric-server-launch.jar", manifest.jarPath)
        assertNull(manifest.argsFile)
    }

    @Test
    fun `keeps the installation successful without a manifest when no start entry is resolvable`() {
        // The recorded installer run leaves no libraries or launch jar behind;
        // the instance keeps the documented legacy start behavior instead of
        // failing the installation after the installer already succeeded.
        val runner = RecordingProcessRunner()
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
        )
        val targetDir = Files.createTempDirectory("instance-forge-no-entry")

        service.downloadInstaller(instance, targetDir)

        assertFalse(
            Files.exists(targetDir.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME)),
            "no manifest may be stored when no start entry is resolvable",
        )
    }

    @Test
    fun `refuses to store the start manifest over a symbolic link`() {
        val runner = RecordingProcessRunner()
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "test-version",
        )
        val targetDir = Files.createTempDirectory("instance-forge-symlink")
        installForgeArgsLayout(targetDir, "1.20.1-47.2.0")
        val outside = Files.createTempFile("start-manifest-outside", ".json")
        Files.writeString(outside, "do not overwrite me")
        val manifestFile = targetDir.resolve(InstanceStartManifestStore.MANIFEST_FILE_NAME)
        val link = runCatching { Files.createSymbolicLink(manifestFile, outside) }
        assumeTrue(link.isSuccess, "This filesystem does not support creating symbolic links")
        try {
            val error = assertThrows<ResponseStatusException> {
                service.downloadInstaller(instance, targetDir)
            }

            assertTrue(error.reason!!.contains("symbolic link"))
            assertTrue(error.reason!!.contains("then start the installation again"))
            assertTrue(Files.isSymbolicLink(manifestFile), "the planted link must remain untouched")
            assertEquals("do not overwrite me", Files.readString(outside))
        } finally {
            Files.deleteIfExists(manifestFile)
            Files.deleteIfExists(outside)
        }
    }

    /** Mirrors the Maven layout a modern Forge `--installServer` run leaves behind. */
    private fun installForgeArgsLayout(directory: Path, version: String) {
        val versionDir = directory.resolve("libraries")
            .resolve("net/minecraftforge/forge")
            .resolve(version)
        Files.createDirectories(versionDir)
        Files.createFile(versionDir.resolve("unix_args.txt"))
        Files.createFile(versionDir.resolve("win_args.txt"))
    }

    @Test
    fun `rejects vanilla creation without a game version before any download`() {
        val runner = RecordingProcessRunner()
        val service = serviceWithLocalArtifacts(runner)
        val instance = Instance(id = UUID.randomUUID(), gameVersion = null, modLoader = ModLoader.VANILLA)

        val error = assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, tempDir.resolve("instance"))
        }

        assertEquals(HttpStatus.BAD_REQUEST, error.statusCode)
        assertTrue(error.reason!!.contains("gameVersion is required"))
        assertNull(runner.lastCommand, "a rejected creation must not run any installer")
    }

    @Test
    fun `rejects vanilla creation when no server jar is published for the version`() {
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.minecraftServerDownload("9.9.9")).thenReturn(null)
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(defaultSettings())
        val runner = RecordingProcessRunner()
        val service = InstanceInstallerService(versionService, serverSettingsService, runner, downloader(), originPolicy(), logger, startManifestStore())
        val instance = Instance(id = UUID.randomUUID(), gameVersion = "9.9.9", modLoader = ModLoader.VANILLA)

        val error = assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, tempDir.resolve("instance"))
        }

        assertEquals(HttpStatus.BAD_REQUEST, error.statusCode)
        assertTrue(error.reason!!.contains("No Minecraft server jar found"))
        assertNull(runner.lastCommand, "a rejected creation must not run any installer")
    }

    @Test
    fun `instance creation chain prepares vanilla without spawning any process`() {
        // Full creation chain as driven by POST /instance: a real InstanceService
        // with the real installer service; the recording runner is the only spawn
        // boundary, so an accidental server run during creation would surface here.
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.minecraftServerDownload("1.20.1")).thenReturn(vanillaDownload())
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(
            defaultSettings().apply { projectPath = tempDir.toString() }
        )
        val runner = RecordingProcessRunner()
        val installerService = InstanceInstallerService(versionService, serverSettingsService, runner, downloader(), originPolicy(), logger, startManifestStore())
        val directories = object : ModdexDirectories {
            override val configDir: Path = tempDir.resolve("config")
            override val dataDir: Path = tempDir.resolve("data")
            override val logsDir: Path = tempDir.resolve("logs")
        }
        val instanceService = InstanceService(
            serverSettingsService, objectMapper, installerService, InstanceModListStore(objectMapper, logger), logger, directories
        )

        val created = instanceService.createAndInstallInstance(
            Instance(name = "Vanilla Chain", gameVersion = "1.20.1", modLoader = ModLoader.VANILLA)
        )

        val instanceDir = instanceService.getInstancePath(created.id!!)
        assertTrue(Files.exists(instanceDir.resolve("server.jar")), "the startable jar must be prepared")
        assertTrue(Files.exists(instanceDir.resolve("instance.json")))
        assertTrue(Files.exists(instanceDir.resolve("modlist.json")))
        assertNull(runner.lastCommand, "the creation request must not spawn or run any process for vanilla")
    }

    @Test
    fun `an installer timeout in the creation chain rolls the reserved directory back`() {
        // The #254 timeout path end to end: the real installer service reports
        // the stopped installer with its guided wording, and the creation rolls
        // back instead of leaving a seemingly ready instance behind.
        val runner = RecordingProcessRunner(
            failure = InstallerCommandTimeoutException(
                "The installer process timed out after 900000 ms and was terminated."
            )
        )
        val instanceService = creationChainService(runner, fixture.url(LOADER_INSTALLER_PATH))

        val error = assertThrows<ResponseStatusException> {
            instanceService.createAndInstallInstance(
                Instance(
                    id = UUID.randomUUID(),
                    name = "Timeout Chain",
                    gameVersion = "1.20.1",
                    modLoader = ModLoader.FORGE,
                    modLoaderVersion = "47.1.0"
                )
            )
        }

        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        assertTrue(error.reason!!.contains("did not finish within the configured time budget"), error.reason)
        assertTrue(error.reason!!.contains("was removed"), "the response must report the rollback")
        assertTrue(error.reason!!.contains(InstanceService.CREATION_FAILURE_RECORDS_DIR))
        assertNull(error.cause)
        assertFalse(
            Files.exists(tempDir.resolve("instances").resolve("Timeout_Chain")),
            "no seemingly ready instance may remain after the rollback",
        )
        assertEquals(emptyList<Any>(), instanceService.getAllInstances())
        assertSingleCreationFailureRecord("Timeout Chain", "download and installation") { it.contains("time budget") }
    }

    @Test
    fun `a rejected artifact download in the creation chain rolls the reserved directory back`() {
        // The download path end to end: the artifact host answers with an error
        // status and the reserved directory is rolled back, not left half-built.
        fixture.serve(REJECTED_INSTALLER_PATH, REJECTED_INSTALLER_BODY, status = 500)
        val runner = RecordingProcessRunner()
        val instanceService = creationChainService(runner, fixture.url(REJECTED_INSTALLER_PATH))

        val error = assertThrows<ResponseStatusException> {
            instanceService.createAndInstallInstance(
                Instance(
                    id = UUID.randomUUID(),
                    name = "Download Failure Chain",
                    gameVersion = "1.20.1",
                    modLoader = ModLoader.FORGE,
                    modLoaderVersion = "47.1.0"
                )
            )
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("answered with HTTP 500"), error.reason)
        assertTrue(error.reason!!.contains("was removed"), "the response must report the rollback")
        assertNull(runner.lastCommand, "a failed download must not reach the installer run")
        assertFalse(Files.exists(tempDir.resolve("instances").resolve("Download_Failure_Chain")))
        assertEquals(emptyList<Any>(), instanceService.getAllInstances())
        assertSingleCreationFailureRecord("Download Failure Chain", "download and installation") {
            it.contains("answered with HTTP 500")
        }
    }

    /**
     * Builds the full creation chain against the local fixture server, with
     * `projectPath` pointing into the temp directory so the instances root is
     * `tempDir/instances` and the diagnosis records land in `tempDir/logs`.
     */
    private fun creationChainService(runner: InstallerCommandRunner, installerUrl: String): InstanceService {
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.loaderDownloadUrl("forge", "47.1.0", "1.20.1")).thenReturn(installerUrl)
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(
            defaultSettings().apply { projectPath = tempDir.toString() }
        )
        val installerService = InstanceInstallerService(versionService, serverSettingsService, runner, downloader(), originPolicy(), logger, startManifestStore())
        val directories = object : ModdexDirectories {
            override val configDir: Path = tempDir.resolve("config")
            override val dataDir: Path = tempDir.resolve("data")
            override val logsDir: Path = tempDir.resolve("logs")
        }
        return InstanceService(
            serverSettingsService, objectMapper, installerService, InstanceModListStore(objectMapper, logger), logger, directories
        )
    }

    private fun assertSingleCreationFailureRecord(
        instanceName: String,
        phase: String,
        detail: (String) -> Boolean,
    ) {
        val recordsDir = tempDir.resolve("logs").resolve(InstanceService.CREATION_FAILURE_RECORDS_DIR)
        val recordFiles = Files.list(recordsDir).use { stream -> stream.map { it.fileName.toString() }.toList() }
        assertEquals(1, recordFiles.size)
        val record = objectMapper.readValue<InstanceCreationFailureRecord>(
            recordsDir.resolve(recordFiles.single()).toFile()
        )
        assertEquals(instanceName, record.instanceName)
        assertEquals(phase, record.phase)
        assertEquals("ResponseStatusException", record.errorKind)
        assertTrue(detail(record.detail ?: ""), "the record must carry the guided failure detail")
    }

    @Test
    fun `downloads fabric installer and vanilla server jar`() {
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.loaderDownloadUrl("fabric", "0.15.11", "1.20.1"))
            .thenReturn(fixture.url(LOADER_INSTALLER_PATH))
        Mockito.`when`(versionService.minecraftServerDownload("1.20.1")).thenReturn(vanillaDownload())
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(defaultSettings())
        val processRunner = RecordingProcessRunner()

        val service = InstanceInstallerService(versionService, serverSettingsService, processRunner, downloader(), originPolicy(), logger, startManifestStore())
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.1",
            modLoader = ModLoader.FABRIC,
            modLoaderVersion = "0.15.11"
        )

        val targetDir = Files.createTempDirectory("instance-fabric")
        service.downloadInstaller(instance, targetDir)

        val installerFile = targetDir.resolve("server-installer.jar")
        val serverJar = targetDir.resolve("server.jar")
        assertTrue(Files.exists(installerFile))
        assertEquals("local fixture, not an executable jar", Files.readString(installerFile))
        assertTrue(Files.exists(serverJar))
        assertEquals("minecraft server fixture", Files.readString(serverJar))

        assertEquals(listOf("java", "-Xmx2G", "-Xms1G", "-jar", "server-installer.jar", "nogui"), processRunner.lastCommand)
        assertEquals(targetDir, processRunner.lastDirectory)
    }

    @Test
    fun `downloads forge installer and runs installServer command`() {
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.loaderDownloadUrl("forge", "47.1.0", "1.20.1"))
            .thenReturn(fixture.url(LOADER_INSTALLER_PATH))
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(defaultSettings())
        val processRunner = RecordingProcessRunner()

        val service = InstanceInstallerService(versionService, serverSettingsService, processRunner, downloader(), originPolicy(), logger, startManifestStore())
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "47.1.0",
            javaXmx = "4G",
            javaXms = "2G"
        )

        val targetDir = Files.createTempDirectory("instance-forge")
        service.downloadInstaller(instance, targetDir)

        val installerFile = targetDir.resolve("server-installer.jar")
        assertTrue(Files.exists(installerFile))
        assertEquals("local fixture, not an executable jar", Files.readString(installerFile))

        assertEquals(listOf("java", "-Xmx4G", "-Xms2G", "-jar", "server-installer.jar", "--installServer"), processRunner.lastCommand)
        assertEquals(targetDir, processRunner.lastDirectory)
    }

    @Test
    fun `records artifact provenance for the loader installer and the vanilla server jar`() {
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.loaderDownloadUrl("fabric", "0.15.11", "1.20.1"))
            .thenReturn(fixture.url(LOADER_INSTALLER_PATH))
        Mockito.`when`(versionService.minecraftServerDownload("1.20.1")).thenReturn(vanillaDownload())
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(defaultSettings())
        val service = InstanceInstallerService(versionService, serverSettingsService, RecordingProcessRunner(), downloader(), originPolicy(), logger, startManifestStore())
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.1",
            modLoader = ModLoader.FABRIC,
            modLoaderVersion = "0.15.11"
        )
        val targetDir = Files.createTempDirectory("instance-provenance")

        service.downloadInstaller(instance, targetDir)

        val provenance = objectMapper.readValue<ArtifactProvenanceFile>(targetDir.resolve("artifact-provenance.json").toFile())
        val loaderRecord = provenance.artifacts[InstanceInstallerService.LOADER_INSTALLER_ARTIFACT]!!
        assertEquals("server-installer.jar", loaderRecord.fileName)
        assertEquals(fixture.baseUrl, loaderRecord.source)
        assertEquals(ArtifactFixtureServer.sha1Hex(LOADER_INSTALLER_BODY), loaderRecord.sha1)
        assertEquals(ChecksumSource.PUBLISHED_SIDECAR, loaderRecord.checksumSource)
        val vanillaRecord = provenance.artifacts[InstanceInstallerService.VANILLA_SERVER_ARTIFACT]!!
        assertEquals("server.jar", vanillaRecord.fileName)
        assertEquals(ArtifactFixtureServer.sha1Hex(VANILLA_SERVER_BODY), vanillaRecord.sha1)
        assertEquals(VANILLA_SERVER_BODY.size.toLong(), vanillaRecord.sizeBytes)
        assertEquals(ChecksumSource.TRUSTED_MANIFEST, vanillaRecord.checksumSource)
    }

    @Test
    fun `rejects a manipulated installer and never starts it`() {
        val genuineSha1 = "0123456789abcdef0123456789abcdef01234567"
        fixture.serve(TAMPERED_INSTALLER_PATH, "tampered payload".toByteArray())
        fixture.serveClaimedSha1Sidecar(TAMPERED_INSTALLER_PATH, genuineSha1)
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versionService.loaderDownloadUrl("forge", "47.1.0", "1.20.1"))
            .thenReturn(fixture.url(TAMPERED_INSTALLER_PATH))
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(defaultSettings())
        val processRunner = RecordingProcessRunner()
        val service = InstanceInstallerService(versionService, serverSettingsService, processRunner, downloader(), originPolicy(), logger, startManifestStore())
        val instance = Instance(
            id = UUID.randomUUID(),
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = "47.1.0"
        )
        val targetDir = Files.createTempDirectory("instance-tampered")

        val error = assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, targetDir)
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("does not match its published checksum"))
        assertTrue(error.reason!!.contains("Start the installation again"))
        assertNull(processRunner.lastCommand, "the installer must not run for a rejected artifact")
        assertFalse(Files.exists(targetDir.resolve("server-installer.jar")))
    }

    @Test
    fun `fails when mod loader version missing for forge`() {
        val versionService = Mockito.mock(VersionService::class.java)
        Mockito.`when`(serverSettingsService.getServerSettings()).thenReturn(defaultSettings())
        val processRunner = RecordingProcessRunner()
        val service = InstanceInstallerService(versionService, serverSettingsService, processRunner, downloader(), originPolicy(), logger, startManifestStore())

        val instance = Instance(
            id = UUID.randomUUID(),
            name = "forge-instance",
            gameVersion = "1.20.1",
            modLoader = ModLoader.FORGE,
            modLoaderVersion = null
        )

        assertThrows<ResponseStatusException> {
            service.downloadInstaller(instance, Files.createTempDirectory("instance-forge-missing"))
        }
    }

    private fun vanillaDownload(): MojangVersionDetail.Download =
        artifactDownload(VANILLA_SERVER_PATH, VANILLA_SERVER_BODY)

    private fun artifactDownload(path: String, body: ByteArray): MojangVersionDetail.Download =
        MojangVersionDetail.Download(
            url = fixture.url(path),
            sha1 = ArtifactFixtureServer.sha1Hex(body),
            size = body.size.toLong(),
        )

    private fun downloader() = SecureArtifactDownloader(logger, ArtifactProvenanceStore(objectMapper, logger), 1_073_741_824L)

    private fun startManifestStore() = InstanceStartManifestStore(objectMapper, logger)

    private fun originPolicy(): ArtifactOriginPolicy {
        val loopback = setOf("127.0.0.1")
        return ArtifactOriginPolicy(
            installerHostsByLoader = ModLoader.entries.associateWith { loopback },
            vanillaServerHosts = loopback,
        )
    }

    companion object {
        private const val LOADER_INSTALLER_PATH = "/loader-installer.jar"
        private const val VANILLA_SERVER_PATH = "/vanilla-server.jar"
        private const val TAMPERED_INSTALLER_PATH = "/tampered-installer.jar"
        private const val REJECTED_INSTALLER_PATH = "/rejected-installer.jar"
        private val LOADER_INSTALLER_BODY = "local fixture, not an executable jar".toByteArray()
        private val VANILLA_SERVER_BODY = "minecraft server fixture".toByteArray()
        private val REJECTED_INSTALLER_BODY = "the host rejects this request".toByteArray()
    }
}

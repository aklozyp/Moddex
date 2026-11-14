package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.services.Logger
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.EnabledOnOs
import org.junit.jupiter.api.condition.OS
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.api.assertThrows
import org.mockito.Mockito
import org.springframework.web.server.ResponseStatusException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermission

@Tag("ci")
@EnabledOnOs(OS.LINUX, OS.MAC)
class DefaultInstallerCommandRunnerIT {

    @TempDir
    lateinit var tempDir: Path

    private val runner = DefaultInstallerCommandRunner(Mockito.mock(Logger::class.java))
    private val fixture = ArtifactFixtureServer()

    @AfterEach
    fun stopFixtureServer() {
        fixture.close()
    }

    @Test
    fun runExecutesShellCommandAndCapturesExitCode() {
        val exitCode = runner.run(listOf("sh", "-c", "echo ok > result.txt"), tempDir, "it-job")

        assertThat(exitCode).isZero()
        val content = Files.readString(tempDir.resolve("result.txt")).trim()
        assertThat(content).isEqualTo("ok")
    }

    @Test
    fun installerExecutesSelectedJavaPathContainingSpaces() {
        val selectedJava = Files.createDirectories(tempDir.resolve("Selected Java 21")).resolve("java")
        Files.writeString(selectedJava, "#!/bin/sh\nprintf '%s\\n' \"\$@\" > selected-java-args.txt\nexit 0\n")
        Files.setPosixFilePermissions(selectedJava, setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_EXECUTE))
        val directory = Files.createDirectory(tempDir.resolve("instance"))

        serviceWithLocalArtifact().downloadInstaller(instance(selectedJava), directory)

        // The fixture is not a valid jar: invoking PATH Java would fail instead of producing this marker.
        assertThat(Files.readAllLines(directory.resolve("selected-java-args.txt")))
            .containsExactly("-Xmx2G", "-Xms1G", "-jar", "server-installer.jar", "--installServer")
    }

    @Test
    fun missingSelectedJavaFailsWithoutPathFallback() {
        val missingJava = tempDir.resolve("Missing Java").resolve("java")
        val directory = Files.createDirectory(tempDir.resolve("instance"))

        val error = assertThrows<ResponseStatusException> {
            serviceWithLocalArtifact().downloadInstaller(instance(missingJava), directory)
        }

        assertThat(error.reason).contains("Could not execute installer", "Check the instance Java path", "then retry")
        assertThat(error.cause).isNull()
    }

    private fun instance(javaPath: Path) = Instance(
        gameVersion = "1.20.1",
        modLoader = ModLoader.FORGE,
        modLoaderVersion = "47.1.0",
        javaPath = javaPath.toString()
    )

    private fun serviceWithLocalArtifact(): InstanceInstallerService {
        val path = "/fixture-installer.jar"
        val body = "local fixture, not an executable jar".toByteArray()
        fixture.serve(path, body)
        fixture.serveSha1Sidecar(path, body)
        val versions = Mockito.mock(VersionService::class.java)
        Mockito.`when`(versions.loaderDownloadUrl("forge", "47.1.0", "1.20.1"))
            .thenReturn(fixture.url(path))
        val settings = Mockito.mock(ServerSettingsService::class.java)
        Mockito.`when`(settings.getServerSettings()).thenReturn(ServerSettings())
        val logger = Mockito.mock(Logger::class.java)
        val downloader = SecureArtifactDownloader(
            logger,
            ArtifactProvenanceStore(com.fasterxml.jackson.module.kotlin.jacksonObjectMapper(), logger),
            1_073_741_824L,
        )
        return InstanceInstallerService(
            versions,
            settings,
            runner,
            downloader,
            ArtifactOriginPolicy(
                installerHostsByLoader = ModLoader.entries.associateWith { setOf("127.0.0.1") },
                vanillaServerHosts = setOf("127.0.0.1"),
            ),
            logger,
            InstanceStartManifestStore(com.fasterxml.jackson.module.kotlin.jacksonObjectMapper(), logger),
        )
    }
}

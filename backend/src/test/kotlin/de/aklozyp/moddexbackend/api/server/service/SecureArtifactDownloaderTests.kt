package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.services.Logger
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.mockito.Mockito
import org.springframework.http.HttpStatus
import org.springframework.web.server.ResponseStatusException
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID

class SecureArtifactDownloaderTests {

    @TempDir
    lateinit var tempDir: Path

    private val logger: Logger = Mockito.mock(Logger::class.java)
    private val objectMapper = jacksonObjectMapper()
    private val provenanceStore = ArtifactProvenanceStore(objectMapper, logger)

    private lateinit var fixture: ArtifactFixtureServer

    @BeforeEach
    fun startFixtureServer() {
        fixture = ArtifactFixtureServer()
    }

    @AfterEach
    fun stopFixtureServer() {
        fixture.close()
    }

    @Test
    fun `stores a verified artifact and its provenance when the published checksum matches`() {
        val body = "genuine installer payload".toByteArray()
        val path = "/installer.jar"
        fixture.serve(path, body)
        fixture.serveSha1Sidecar(path, body)

        downloader().download(request(fixture.url(path)), tempDir.resolve("installer.jar"))

        val target = tempDir.resolve("installer.jar")
        assertTrue(Files.exists(target))
        assertEquals("genuine installer payload", Files.readString(target))

        val provenance = readProvenance()
        val record = provenance.artifacts["test-artifact"]!!
        assertEquals("installer.jar", record.fileName)
        assertEquals(fixture.baseUrl, record.source)
        assertEquals(ArtifactFixtureServer.sha1Hex(body), record.sha1)
        assertEquals(ArtifactFixtureServer.sha256Hex(body), record.sha256)
        assertEquals(body.size.toLong(), record.sizeBytes)
        assertEquals(ChecksumSource.PUBLISHED_SIDECAR, record.checksumSource)
        assertTrue(record.downloadedAt.isNotBlank())

        assertEquals(
            setOf("installer.jar", "artifact-provenance.json"),
            listDirectoryFileNames(),
            "no partially downloaded artifact may remain in the instance directory",
        )
    }

    @Test
    fun `verifies an expected manifest checksum without consulting a side artifact`() {
        val body = "manifest verified jar".toByteArray()
        val path = "/vanilla.jar"
        fixture.serve(path, body)

        val expected = ArtifactFixtureServer.sha1Hex(body)
        downloader().download(request(fixture.url(path), expectedSha1 = expected), tempDir.resolve("vanilla.jar"))

        assertTrue(Files.exists(tempDir.resolve("vanilla.jar")))
        assertEquals(0, fixture.hits("$path.sha1"), "a trusted manifest checksum must be used directly")
        assertEquals(ChecksumSource.TRUSTED_MANIFEST, readProvenance().artifacts["test-artifact"]!!.checksumSource)
    }

    @Test
    fun `rejects a vanilla artifact whose body contradicts the manifest checksum`() {
        val genuine = "genuine vanilla jar".toByteArray()
        val tampered = "tampered vanilla jar".toByteArray()
        val path = "/vanilla.jar"
        fixture.serve(path, tampered)

        val error = assertThrows<ResponseStatusException> {
            downloader().download(
                request(fixture.url(path), expectedSha1 = ArtifactFixtureServer.sha1Hex(genuine)),
                tempDir.resolve("vanilla.jar"),
            )
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("does not match its published checksum"))
        assertEquals(
            0,
            fixture.hits("$path.sha1"),
            "a trusted manifest checksum must be used directly, without a side artifact request",
        )
        assertFalse(Files.exists(tempDir.resolve("vanilla.jar")))
        assertTrue(listDirectoryFileNames().isEmpty(), "no partially downloaded artifact may remain")
    }

    @Test
    fun `falls back to origin pinning when no checksum side artifact is published`() {
        val body = "side-artifact-less jar".toByteArray()
        fixture.serve("/no-checksum.jar", body)

        downloader().download(request(fixture.url("/no-checksum.jar")), tempDir.resolve("no-checksum.jar"))

        assertTrue(Files.exists(tempDir.resolve("no-checksum.jar")))
        assertEquals(ChecksumSource.ORIGIN_PINNED_ONLY, readProvenance().artifacts["test-artifact"]!!.checksumSource)
    }

    @Test
    fun `rejects a manipulated artifact before it is placed`() {
        val genuine = "genuine installer payload".toByteArray()
        val tampered = "tampered installer payload".toByteArray()
        val path = "/installer.jar"
        fixture.serve(path, tampered)
        fixture.serveClaimedSha1Sidecar(path, ArtifactFixtureServer.sha1Hex(genuine))

        val error = assertThrows<ResponseStatusException> {
            downloader().download(request(fixture.url(path)), tempDir.resolve("installer.jar"))
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("does not match its published checksum"))
        assertTrue(error.reason!!.contains("Start the installation again"))
        assertFalse(error.reason!!.contains(fixture.baseUrl), "the error response must not echo the raw download URL")
        assertFalse(Files.exists(tempDir.resolve("installer.jar")))
        assertTrue(listDirectoryFileNames().isEmpty(), "no partially downloaded artifact may remain")
        assertFalse(Files.exists(tempDir.resolve("artifact-provenance.json")))
    }

    @Test
    fun `rejects an artifact exceeding the configured size limit`() {
        val body = ByteArray(1024) { 'x'.code.toByte() }
        fixture.serve("/large.jar", body)

        val smallLimitDownloader = SecureArtifactDownloader(logger, provenanceStore, 16L)
        val error = assertThrows<ResponseStatusException> {
            smallLimitDownloader.download(request(fixture.url("/large.jar")), tempDir.resolve("large.jar"))
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("maximum download size"))
        assertTrue(error.reason!!.contains("review the configured download size limit"))
        assertFalse(Files.exists(tempDir.resolve("large.jar")))
        assertTrue(listDirectoryFileNames().isEmpty())
    }

    @Test
    fun `rejects an artifact whose size deviates from the manifest`() {
        val body = "short".toByteArray()
        fixture.serve("/vanilla.jar", body)

        val error = assertThrows<ResponseStatusException> {
            downloader().download(request(fixture.url("/vanilla.jar"), expectedSizeBytes = 100), tempDir.resolve("vanilla.jar"))
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("size does not match the published size"))
        assertFalse(Files.exists(tempDir.resolve("vanilla.jar")))
    }

    @Test
    fun `reports an unreachable artifact host with a safe next action`() {
        val closedPort = ServerSocket(0).use { it.localPort }
        val error = assertThrows<ResponseStatusException> {
            downloader().download(request("http://127.0.0.1:$closedPort/installer.jar"), tempDir.resolve("installer.jar"))
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("could not be reached"))
        assertTrue(error.reason!!.contains("Check the backend's network access"))
        assertFalse(Files.exists(tempDir.resolve("installer.jar")))
    }

    @Test
    fun `rejects downloads from hosts outside the pinned origin`() {
        val body = "host hijack attempt".toByteArray()
        fixture.serve("/installer.jar", body)

        val error = assertThrows<ResponseStatusException> {
            downloader().download(
                request(fixture.url("/installer.jar"), allowedHosts = setOf("maven.fabricmc.net")),
                tempDir.resolve("installer.jar"),
            )
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("origin"))
        assertTrue(error.reason!!.contains("is not an allowed artifact host"))
        assertEquals(0, fixture.hits("/installer.jar"), "the download must be refused before any request")
        assertFalse(Files.exists(tempDir.resolve("installer.jar")))
    }

    @Test
    fun `rejects plain HTTP origins outside loopback`() {
        val error = assertThrows<ResponseStatusException> {
            downloader().download(
                request("http://maven.fabricmc.net/installer.jar", allowedHosts = setOf("maven.fabricmc.net")),
                tempDir.resolve("installer.jar"),
            )
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("HTTPS"))
        assertEquals(0, fixture.hits("/installer.jar"))
        assertFalse(Files.exists(tempDir.resolve("installer.jar")))
    }

    @Test
    fun `rejects download URLs with embedded credentials and does not echo them`() {
        val secret = "s3cret-token"
        val url = "http://user:$secret@127.0.0.1:${fixture.baseUrl.substringAfterLast(':')}/installer.jar"

        val error = assertThrows<ResponseStatusException> {
            downloader().download(request(url), tempDir.resolve("installer.jar"))
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("embedded credentials"))
        assertFalse(error.reason!!.contains(secret), "no credential material may leak into the error message")
        assertFalse(Files.exists(tempDir.resolve("installer.jar")))
    }

    @Test
    fun `rejects a redirect to a different origin`() {
        fixture.serveRedirect("/redirected-installer.jar", "http://maven.fabricmc.net/installer.jar")

        val error = assertThrows<ResponseStatusException> {
            downloader().download(request(fixture.url("/redirected-installer.jar")), tempDir.resolve("installer.jar"))
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("origin"))
        assertTrue(error.reason!!.contains("is not a secure HTTPS endpoint"))
        assertFalse(Files.exists(tempDir.resolve("installer.jar")))
    }

    @Test
    fun `follows a redirect within the pinned origin and verifies the final artifact`() {
        val body = "redirected installer payload".toByteArray()
        fixture.serveRedirect("/staged/installer.jar", fixture.url("/final/installer.jar"))
        fixture.serve("/final/installer.jar", body)
        fixture.serveSha1Sidecar("/final/installer.jar", body)

        downloader().download(request(fixture.url("/staged/installer.jar")), tempDir.resolve("installer.jar"))

        assertTrue(Files.exists(tempDir.resolve("installer.jar")))
        assertEquals("redirected installer payload", Files.readString(tempDir.resolve("installer.jar")))
        // Each hop is requested exactly once; the artifact comes from the redirect target.
        assertEquals(1, fixture.hits("/staged/installer.jar"))
        assertEquals(1, fixture.hits("/final/installer.jar"))
        // The published checksum is fetched for the final URI the artifact came from.
        assertEquals(1, fixture.hits("/final/installer.jar.sha1"))
        assertEquals(0, fixture.hits("/staged/installer.jar.sha1"))
        assertEquals(ChecksumSource.PUBLISHED_SIDECAR, readProvenance().artifacts["test-artifact"]!!.checksumSource)
    }

    @Test
    fun `keeps no artifact when its provenance cannot be stored`() {
        val body = "provenance broken".toByteArray()
        fixture.serve("/installer.jar", body)
        fixture.serveSha1Sidecar("/installer.jar", body)
        Files.writeString(tempDir.resolve("artifact-provenance.json"), "{ this is not json")

        val error = assertThrows<ResponseStatusException> {
            downloader().download(request(fixture.url("/installer.jar")), tempDir.resolve("installer.jar"))
        }

        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        assertTrue(error.reason!!.contains("provenance"))
        assertTrue(error.reason!!.contains("artifact-provenance.json"))
        assertFalse(Files.exists(tempDir.resolve("installer.jar")), "an artifact without provenance must not remain")
    }

    @Test
    fun `rejects a symbolic link at the artifact target`() {
        val body = "symlink target".toByteArray()
        fixture.serve("/installer.jar", body)
        fixture.serveSha1Sidecar("/installer.jar", body)
        val outside = Files.createTempFile("symlink-outside", ".jar")
        Files.writeString(outside, "do not overwrite me")
        val createdLink = runCatching { Files.createSymbolicLink(tempDir.resolve("installer.jar"), outside) }
        assumeTrue(createdLink.isSuccess, "This filesystem does not support creating symbolic links")
        val link = createdLink.getOrThrow()

        val error = assertThrows<ResponseStatusException> {
            downloader().download(request(fixture.url("/installer.jar")), link)
        }

        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        assertTrue(error.reason!!.contains("symbolic link"))
        assertEquals("do not overwrite me", Files.readString(outside))
        // The rejected symlink itself remains untouched at the target; the
        // download attempt must not have left any partial artifact next to it.
        assertEquals(setOf("installer.jar"), listDirectoryFileNames())
    }

    @Test
    fun `translates a blocked artifact target into a storage failure instead of an upstream error`() {
        val body = "storage failure fixture".toByteArray()
        fixture.serve("/installer.jar", body)
        fixture.serveSha1Sidecar("/installer.jar", body)
        // A non-empty directory at the target path makes the atomic move fail
        // with a FileSystemException on every platform.
        val blockedTarget = Files.createDirectories(tempDir.resolve("server-installer.jar"))
        Files.writeString(blockedTarget.resolve("occupied.txt"), "makes the directory non-empty")

        val error = assertThrows<ResponseStatusException> {
            downloader().download(request(fixture.url("/installer.jar")), tempDir.resolve("server-installer.jar"))
        }

        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, error.statusCode)
        assertTrue(error.reason!!.contains("could not be stored in the instance directory"))
        assertTrue(error.reason!!.contains("Check the instance directory permissions"))
        assertFalse(error.reason!!.contains("could not be reached"), "a local storage failure must not be reported as an unreachable host")
        assertTrue(listDirectoryFileNames().none { it.endsWith(".downloading") }, "no partially downloaded artifact may remain")
    }

    @Test
    fun `does not treat lookalike loopback hosts as loopback`() {
        val error = assertThrows<ResponseStatusException> {
            downloader().download(
                request("http://127.0.0.1.evil.com/installer.jar", allowedHosts = setOf("127.0.0.1.evil.com")),
                tempDir.resolve("installer.jar"),
            )
        }

        assertEquals(HttpStatus.BAD_GATEWAY, error.statusCode)
        assertTrue(error.reason!!.contains("is not a secure HTTPS endpoint"), "a lookalike loopback host must not receive the plain-HTTP allowance")
        assertFalse(Files.exists(tempDir.resolve("installer.jar")))
    }

    private fun downloader() = SecureArtifactDownloader(logger, provenanceStore, 1_073_741_824L)

    private fun request(
        url: String,
        expectedSha1: String? = null,
        expectedSizeBytes: Long? = null,
        allowedHosts: Set<String> = setOf("127.0.0.1"),
    ) = ArtifactDownloadRequest(
        artifactName = "test-artifact",
        downloadUrl = url,
        allowedHosts = allowedHosts,
        instanceId = UUID.randomUUID(),
        expectedSha1 = expectedSha1,
        expectedSizeBytes = expectedSizeBytes,
    )

    private fun readProvenance(): ArtifactProvenanceFile =
        objectMapper.readValue<ArtifactProvenanceFile>(tempDir.resolve("artifact-provenance.json").toFile())

    private fun listDirectoryFileNames(): Set<String> =
        Files.list(tempDir).use { stream -> stream.map { it.fileName.toString() }.collect(java.util.stream.Collectors.toSet()) }
}

package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.services.Logger
import org.springframework.beans.factory.annotation.Value
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.nio.file.FileSystemException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

/**
 * Describes one artifact download. `allowedHosts` pins the canonical origin of
 * the provider, the optional expected checksums and size come from a trusted
 * metadata manifest when the provider publishes one.
 */
data class ArtifactDownloadRequest(
    val artifactName: String,
    val downloadUrl: String,
    val allowedHosts: Set<String>,
    val instanceId: UUID? = null,
    val expectedSha1: String? = null,
    val expectedSha256: String? = null,
    val expectedSizeBytes: Long? = null,
)

private data class StreamedArtifact(
    val uri: URI,
    val sizeBytes: Long,
    val sha1: String,
    val sha256: String,
)

/**
 * Downloads installer artifacts with origin pinning, a size limit and checksum
 * verification before the artifact is placed in the instance directory. The
 * artifact is streamed to a temporary file, verified, and only then moved to
 * its target name, so a manipulated, oversized or interrupted download never
 * leaves a startable artifact behind. Origin and verified checksums are
 * recorded in the instance provenance file.
 */
@Service
class SecureArtifactDownloader(
    private val logger: Logger,
    private val provenanceStore: ArtifactProvenanceStore,
    @Value("\${moddex.artifacts.max-download-size-bytes:1073741824}")
    private val maxDownloadSizeBytes: Long = DEFAULT_MAX_DOWNLOAD_SIZE_BYTES,
) {

    init {
        require(maxDownloadSizeBytes > 0) { "Artifact download size limit must be greater than zero" }
    }

    fun download(request: ArtifactDownloadRequest, targetFile: Path) {
        val parent = targetFile.parent ?: throw ResponseStatusException(
            HttpStatus.INTERNAL_SERVER_ERROR,
            artifactFailure(request, "the instance directory could not be resolved", "Check the instance directory, then start the installation again"),
        )
        val artifactUri = parseArtifactUrl(request)
        logger.info("Downloading ${request.artifactName} for instance id=${request.instanceId} from ${originOf(artifactUri)}")

        try {
            Files.createDirectories(parent)
        } catch (ex: Exception) {
            logger.error("Could not create the instance directory $parent for ${request.artifactName}: ${ex.javaClass.simpleName}")
            throw ResponseStatusException(
                HttpStatus.INTERNAL_SERVER_ERROR,
                artifactFailure(request, "the instance directory could not be created", "Check the instance directory permissions, then start the installation again"),
            )
        }

        val tempFile = try {
            Files.createTempFile(parent, ".${targetFile.fileName}-", ".downloading")
        } catch (ex: Exception) {
            logger.error("Could not create a temporary download file in $parent for ${request.artifactName}: ${ex.javaClass.simpleName}")
            throw ResponseStatusException(
                HttpStatus.INTERNAL_SERVER_ERROR,
                artifactFailure(request, "a temporary download file could not be created", "Check the instance directory permissions and free disk space, then start the installation again"),
            )
        }
        try {
            rejectSymbolicLink(targetFile, request)
            val streamed = streamArtifact(artifactUri, request, tempFile)
            verifySize(streamed, request)
            val checksumSource = verifyChecksum(streamed, request)
            Files.move(tempFile, targetFile, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            recordProvenance(request, parent, targetFile, streamed, checksumSource)
            logger.info(
                "Verified ${request.artifactName} for instance id=${request.instanceId}: " +
                    "size=${streamed.sizeBytes}, sha1=${streamed.sha1}, checksumSource=$checksumSource"
            )
        } catch (ex: Exception) {
            deleteQuietly(tempFile)
            throw translate(ex, request)
        }
    }

    private fun parseArtifactUrl(request: ArtifactDownloadRequest): URI {
        val uri = try {
            URI(request.downloadUrl)
        } catch (ex: Exception) {
            logger.error("Invalid ${request.artifactName} URL for instance id=${request.instanceId}: ${ex.javaClass.simpleName}")
            throw ResponseStatusException(
                HttpStatus.BAD_GATEWAY,
                artifactFailure(request, "the version metadata returned an invalid download address", "Start the installation again; if it keeps failing, check the provider's version metadata"),
            )
        }
        validateOrigin(uri, request.allowedHosts, request)
        return uri
    }

    private fun validateOrigin(uri: URI, allowedHosts: Set<String>, request: ArtifactDownloadRequest) {
        val conflict = { reason: String ->
            ResponseStatusException(
                HttpStatus.BAD_GATEWAY,
                artifactFailure(request, "the artifact origin $reason", "Start the installation again; if it keeps failing, verify that the provider's version metadata is intact"),
            )
        }
        if (allowedHosts.isEmpty()) throw conflict("is not pinned to an allowed host")
        val host = uri.host?.lowercase()
            ?: throw conflict("could not be resolved to a host")
        val scheme = uri.scheme?.lowercase()
            ?: throw conflict("has no valid scheme")
        if (scheme != "https" && !(scheme == "http" && isLoopbackHost(host))) {
            throw conflict("is not a secure HTTPS endpoint")
        }
        if (uri.userInfo != null) throw conflict("contains embedded credentials")
        if (host !in allowedHosts) throw conflict("is not an allowed artifact host")
    }

    private class OpenedArtifactConnection(val connection: HttpURLConnection, val uri: URI)

    /**
     * Opens the connection and follows redirects manually, so a redirect to
     * another origin is rejected instead of silently changing the artifact
     * source. Returns the connection together with the final (post-redirect)
     * URI, which is the origin the artifact actually came from.
     */
    private fun openConnection(uri: URI, request: ArtifactDownloadRequest): OpenedArtifactConnection {
        var current = uri
        repeat(MAX_REDIRECTS + 1) { attempt ->
            validateOrigin(current, request.allowedHosts, request)
            val connection = current.toURL().openConnection() as HttpURLConnection
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            val status = connection.responseCode
            if (status in 300..399) {
                val location = connection.getHeaderField("Location")
                connection.disconnect()
                if (attempt == MAX_REDIRECTS) {
                    throw redirectFailure(request, "redirected too many times")
                }
                if (location.isNullOrBlank()) {
                    throw redirectFailure(request, "redirected without a target address")
                }
                current = try {
                    current.resolve(location)
                } catch (ex: Exception) {
                    throw redirectFailure(request, "redirected to an invalid address")
                }
                return@repeat
            }
            return OpenedArtifactConnection(connection, current)
        }
        throw redirectFailure(request, "redirected too many times")
    }

    private fun redirectFailure(request: ArtifactDownloadRequest, reason: String): ResponseStatusException =
        ResponseStatusException(
            HttpStatus.BAD_GATEWAY,
            artifactFailure(request, "the artifact host $reason", "Start the installation again; if it keeps failing, verify that the provider's version metadata is intact"),
        )

    private fun streamArtifact(uri: URI, request: ArtifactDownloadRequest, tempFile: Path): StreamedArtifact {
        val opened = openConnection(uri, request)
        val connection = opened.connection
        try {
            val status = connection.responseCode
            if (status != HttpURLConnection.HTTP_OK) {
                throw ResponseStatusException(
                    HttpStatus.BAD_GATEWAY,
                    artifactFailure(request, "the artifact host answered with HTTP $status", "Start the installation again; if it keeps failing, check the provider's availability"),
                )
            }
            checkDeclaredSize(connection.contentLengthLong, request)
            val sha1 = MessageDigest.getInstance("SHA-1")
            val sha256 = MessageDigest.getInstance("SHA-256")
            var bytes = 0L
            connection.getInputStream().use { input ->
                Files.newOutputStream(tempFile).use { output ->
                    val buffer = ByteArray(STREAM_BUFFER_BYTES)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        bytes += read
                        if (bytes > maxDownloadSizeBytes) {
                            throw ResponseStatusException(
                                HttpStatus.BAD_GATEWAY,
                                artifactFailure(
                                    request,
                                    "the artifact exceeds the maximum download size of $maxDownloadSizeBytes bytes",
                                    "Start the installation again; if the official artifact is genuinely this large, review the configured download size limit",
                                ),
                            )
                        }
                        request.expectedSizeBytes?.let { expected ->
                            if (bytes > expected) {
                                throw sizeMismatch(request)
                            }
                        }
                        sha1.update(buffer, 0, read)
                        sha256.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                    }
                }
            }
            return StreamedArtifact(opened.uri, bytes, sha1.digest().toLowercaseHex(), sha256.digest().toLowercaseHex())
        } finally {
            connection.disconnect()
        }
    }

    private fun checkDeclaredSize(declaredLength: Long, request: ArtifactDownloadRequest) {
        if (declaredLength < 0) return
        if (declaredLength > maxDownloadSizeBytes) {
            throw ResponseStatusException(
                HttpStatus.BAD_GATEWAY,
                artifactFailure(
                    request,
                    "the artifact exceeds the maximum download size of $maxDownloadSizeBytes bytes",
                    "Start the installation again; if the official artifact is genuinely this large, review the configured download size limit",
                ),
            )
        }
        request.expectedSizeBytes?.let { expected ->
            if (declaredLength != expected) throw sizeMismatch(request)
        }
    }

    private fun verifySize(streamed: StreamedArtifact, request: ArtifactDownloadRequest) {
        request.expectedSizeBytes?.let { expected ->
            if (streamed.sizeBytes != expected) throw sizeMismatch(request)
        }
    }

    private fun verifyChecksum(streamed: StreamedArtifact, request: ArtifactDownloadRequest): ChecksumSource {
        val expectedSha1 = request.expectedSha1?.takeIf { it.isNotBlank() }?.lowercase()
        val expectedSha256 = request.expectedSha256?.takeIf { it.isNotBlank() }?.lowercase()
        val mismatch = {
            ResponseStatusException(
                HttpStatus.BAD_GATEWAY,
                artifactFailure(
                    request,
                    "the downloaded artifact does not match its published checksum",
                    "Start the installation again; if it keeps failing, do not use the artifact and check the provider for signs of a compromised download",
                ),
            )
        }
        if (expectedSha1 != null && expectedSha1 != streamed.sha1) throw mismatch()
        if (expectedSha256 != null && expectedSha256 != streamed.sha256) throw mismatch()
        if (expectedSha1 != null || expectedSha256 != null) return ChecksumSource.TRUSTED_MANIFEST

        val sidecarSha1 = fetchSidecarSha1(streamed.uri, request)
        if (sidecarSha1 == null) {
            // A missing published checksum must stay visible: the artifact is
            // then only origin-pinned and size-limited, not checksum-verified.
            logger.warn(
                "No published checksum found for ${request.artifactName} (instance id=${request.instanceId}); " +
                    "the artifact will be installed with origin pinning only, without checksum verification"
            )
            return ChecksumSource.ORIGIN_PINNED_ONLY
        }
        if (sidecarSha1 != streamed.sha1) throw mismatch()
        return ChecksumSource.PUBLISHED_SIDECAR
    }

    /**
     * Fetches the published `.sha1` side artifact (Maven-style) when no
     * trusted manifest checksum was provided. A missing side artifact is not
     * an error; the download then relies on origin pinning and the size limit.
     */
    private fun fetchSidecarSha1(uri: URI, request: ArtifactDownloadRequest): String? {
        val sidecarUri = try {
            URI(uri.toString() + ".sha1")
        } catch (ex: Exception) {
            throw ResponseStatusException(
                HttpStatus.BAD_GATEWAY,
                artifactFailure(request, "published checksum address could not be resolved", "Start the installation again; if it keeps failing, check the provider's artifact repository"),
            )
        }
        validateOrigin(sidecarUri, request.allowedHosts, request)
        val connection = openConnection(sidecarUri, request).connection
        try {
            val status = connection.responseCode
            if (status == HttpURLConnection.HTTP_NOT_FOUND) return null
            if (status != HttpURLConnection.HTTP_OK) {
                throw ResponseStatusException(
                    HttpStatus.BAD_GATEWAY,
                    artifactFailure(request, "the published checksum could not be retrieved (HTTP $status)", "Start the installation again; if it keeps failing, check the provider's artifact repository"),
                )
            }
            if (connection.contentLengthLong > MAX_CHECKSUM_SIDECAR_BYTES) {
                throw checksumSidecarFailure(request)
            }
            val body = connection.getInputStream().use { input ->
                val bytes = input.readNBytes(MAX_CHECKSUM_SIDECAR_BYTES + 1)
                if (bytes.size > MAX_CHECKSUM_SIDECAR_BYTES) throw checksumSidecarFailure(request)
                String(bytes, Charsets.UTF_8)
            }
            val checksum = body.trim().split(Regex("\\s+")).firstOrNull()?.lowercase()
            if (checksum == null || !checksum.matches(Regex("[0-9a-f]{40}"))) {
                throw checksumSidecarFailure(request)
            }
            return checksum
        } finally {
            connection.disconnect()
        }
    }

    private fun recordProvenance(
        request: ArtifactDownloadRequest,
        instanceDirectory: Path,
        targetFile: Path,
        streamed: StreamedArtifact,
        checksumSource: ChecksumSource,
    ) {
        val record = ArtifactProvenanceRecord(
            fileName = targetFile.fileName.toString(),
            source = originOf(streamed.uri),
            sha256 = streamed.sha256,
            sha1 = streamed.sha1,
            sizeBytes = streamed.sizeBytes,
            checksumSource = checksumSource,
            downloadedAt = Instant.now().toString(),
        )
        try {
            provenanceStore.record(instanceDirectory, request.artifactName, record)
        } catch (ex: ResponseStatusException) {
            // Fail-safe trade-off: removing the artifact leaves a possibly stale
            // provenance entry pointing at a missing file, but the invariant
            // "no artifact without a provenance record" wins. A stale entry is
            // visible, auditable state; an unrecorded artifact would not be.
            deleteQuietly(targetFile)
            throw ex
        } catch (ex: Exception) {
            deleteQuietly(targetFile)
            logger.error("Could not record provenance for ${request.artifactName}, instance id=${request.instanceId}: ${ex.javaClass.simpleName}")
            throw ResponseStatusException(
                HttpStatus.INTERNAL_SERVER_ERROR,
                artifactFailure(request, "the artifact provenance could not be stored", "Check the instance directory permissions, then start the installation again"),
            )
        }
    }

    private fun rejectSymbolicLink(targetFile: Path, request: ArtifactDownloadRequest) {
        val attributes = try {
            Files.readAttributes(targetFile, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        } catch (_: NoSuchFileException) {
            null
        }
        if (attributes?.isSymbolicLink == true) {
            throw ResponseStatusException(
                HttpStatus.INTERNAL_SERVER_ERROR,
                artifactFailure(request, "the artifact target is a symbolic link", "Remove the symbolic link from the instance directory, then start the installation again"),
            )
        }
    }

    private fun translate(ex: Exception, request: ArtifactDownloadRequest): ResponseStatusException {
        if (ex is ResponseStatusException) return ex
        return when (ex) {
            // Filesystem failures (permissions, atomic-move support, blocked
            // targets) are local problems, not upstream problems: they must
            // never surface as a misleading "host could not be reached".
            is FileSystemException -> {
                logger.error("Could not store ${request.artifactName} for instance id=${request.instanceId}: ${ex.javaClass.simpleName}: ${ex.message ?: "<no detail>"}")
                ResponseStatusException(
                    HttpStatus.INTERNAL_SERVER_ERROR,
                    artifactFailure(request, "the artifact could not be stored in the instance directory", "Check the instance directory permissions and atomic move support, then start the installation again"),
                )
            }
            is SocketTimeoutException -> ResponseStatusException(
                HttpStatus.GATEWAY_TIMEOUT,
                artifactFailure(request, "the artifact host did not answer in time", "Check the backend's network access, then start the installation again"),
            )
            is IOException -> {
                logger.error("Download of ${request.artifactName} failed for instance id=${request.instanceId}: ${ex.javaClass.simpleName}: ${ex.message ?: "<no detail>"}")
                ResponseStatusException(
                    HttpStatus.BAD_GATEWAY,
                    artifactFailure(request, "the artifact host could not be reached", "Check the backend's network access, then start the installation again"),
                )
            }
            else -> {
                logger.error("Download of ${request.artifactName} failed for instance id=${request.instanceId}: ${ex.javaClass.simpleName}: ${ex.message ?: "<no detail>"}")
                ResponseStatusException(
                    HttpStatus.INTERNAL_SERVER_ERROR,
                    artifactFailure(request, "the artifact could not be stored", "Check the instance directory permissions and atomic move support, then start the installation again"),
                )
            }
        }
    }

    private fun sizeMismatch(request: ArtifactDownloadRequest): ResponseStatusException = ResponseStatusException(
        HttpStatus.BAD_GATEWAY,
        artifactFailure(request, "the artifact size does not match the published size", "Start the installation again; if it keeps failing, verify that the provider's version metadata is intact"),
    )

    private fun checksumSidecarFailure(request: ArtifactDownloadRequest): ResponseStatusException = ResponseStatusException(
        HttpStatus.BAD_GATEWAY,
        artifactFailure(request, "the published checksum side artifact is missing or malformed", "Start the installation again; if it keeps failing, check the provider's artifact repository"),
    )

    private fun artifactFailure(request: ArtifactDownloadRequest, problem: String, nextAction: String): String =
        "The ${request.artifactName.replace('-', ' ')} download was rejected because $problem. $nextAction."

    private fun originOf(uri: URI): String {
        val host = uri.host?.lowercase() ?: return ""
        val port = uri.port
        return if (port == -1 || port == uri.scheme?.let { defaultPortOf(it) }) {
            "${uri.scheme?.lowercase()}://$host"
        } else {
            "${uri.scheme?.lowercase()}://$host:$port"
        }
    }

    private fun defaultPortOf(scheme: String): Int? = when (scheme.lowercase()) {
        "http" -> 80
        "https" -> 443
        else -> null
    }

    /**
     * Exact loopback detection, deliberately fail-closed: only the literal
     * `localhost`, the IPv4 127.0.0.0/8 range and the IPv6 loopback forms
     * qualify. Lookalike hosts such as `127.0.0.1.evil.com` must not receive
     * the plain-HTTP allowance; they require HTTPS like any other origin.
     */
    private fun isLoopbackHost(host: String): Boolean =
        host == "localhost" ||
            host == "::1" ||
            host == "0:0:0:0:0:0:0:1" ||
            LOOPBACK_IPV4_REGEX.matches(host)

    private fun deleteQuietly(file: Path) {
        try {
            Files.deleteIfExists(file)
        } catch (_: Exception) {
            logger.warn("Could not remove a partially downloaded artifact. Check the instance directory permissions.")
        }
    }

    private fun ByteArray.toLowercaseHex(): String = joinToString("") { "%02x".format(it) }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val READ_TIMEOUT_MS = 60_000
        private const val MAX_REDIRECTS = 3
        private const val STREAM_BUFFER_BYTES = 64 * 1024
        private const val MAX_CHECKSUM_SIDECAR_BYTES = 16 * 1024
        private const val DEFAULT_MAX_DOWNLOAD_SIZE_BYTES = 1_073_741_824L
        private val LOOPBACK_IPV4_REGEX = Regex("^127(\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$")
    }
}

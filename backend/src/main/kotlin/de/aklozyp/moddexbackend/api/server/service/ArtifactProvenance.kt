package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Component
import org.springframework.web.server.ResponseStatusException
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.time.Instant

/**
 * Where the verified checksum expectation came from. The checksum source is
 * stored alongside the artifact so operators can judge how strongly the copy
 * in an instance directory was verified.
 *
 * Checksum verification detects corruption in transit or in storage; it does
 * not by itself prove authenticity against a compromised provider host that
 * also serves a matching checksum. That authenticity guarantee comes from
 * HTTPS plus the pinned canonical origin.
 */
enum class ChecksumSource {
    /** Checksum was delivered by a trusted metadata manifest (for example the Mojang version detail). */
    TRUSTED_MANIFEST,

    /**
     * Checksum was fetched from the published `.sha1` side artifact next to
     * the download. Catches transit and storage corruption of the artifact,
     * but the checksum comes from the same origin as the artifact, so a fully
     * compromised provider host could serve a matching pair; authenticity
     * rests on TLS and the pinned canonical host.
     */
    PUBLISHED_SIDECAR,

    /**
     * No published checksum was available; the origin pinning and the size
     * limit were the only checks. This is a deliberate, visible downgrade in
     * the provenance record: the copy was not verified against any checksum.
     */
    ORIGIN_PINNED_ONLY,
}

data class ArtifactProvenanceRecord(
    val fileName: String,
    val source: String,
    val sha256: String?,
    val sha1: String?,
    val sizeBytes: Long,
    val checksumSource: ChecksumSource,
    val downloadedAt: String,
)

data class ArtifactProvenanceFile(
    val artifacts: MutableMap<String, ArtifactProvenanceRecord> = LinkedHashMap(),
)

/**
 * Persists which artifact copies were downloaded from where and against which
 * checksums they were verified. The records live in a dedicated
 * `artifact-provenance.json` file in the instance directory and are written
 * atomically; nothing is mixed into `instance.json`.
 */
@Component
class ArtifactProvenanceStore(
    private val objectMapper: ObjectMapper,
    private val logger: Logger,
) {

    @Synchronized
    fun record(instanceDirectory: Path, artifactName: String, provenance: ArtifactProvenanceRecord) {
        val target = instanceDirectory.resolve(PROVENANCE_FILE_NAME)
        val existing = readProvenanceFile(target)
        existing.artifacts[artifactName] = provenance
        writeJsonAtomically(target, objectMapper, existing, logger) { pendingFile ->
            rejectSymbolicLink(target)
            Files.move(pendingFile, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        }
    }

    private fun readProvenanceFile(target: Path): ArtifactProvenanceFile {
        if (!Files.exists(target)) {
            return ArtifactProvenanceFile()
        }
        return try {
            objectMapper.readValue(target.toFile(), ArtifactProvenanceFile::class.java)
        } catch (ex: Exception) {
            logger.error("Could not read $PROVENANCE_FILE_NAME in ${target.parent.toAbsolutePath()}: ${ex.javaClass.simpleName}")
            throw ResponseStatusException(
                HttpStatus.INTERNAL_SERVER_ERROR,
                "Could not update the artifact provenance file of this instance. Review and remove the existing " +
                    "$PROVENANCE_FILE_NAME file in the instance directory, then start the installation again.",
            )
        }
    }

    private fun rejectSymbolicLink(target: Path) {
        val attributes = try {
            Files.readAttributes(target, BasicFileAttributes::class.java, java.nio.file.LinkOption.NOFOLLOW_LINKS)
        } catch (_: NoSuchFileException) {
            null
        }
        if (attributes?.isSymbolicLink == true) {
            throw ResponseStatusException(
                HttpStatus.INTERNAL_SERVER_ERROR,
                "The artifact provenance file is a symbolic link. Remove it from the instance directory, " +
                    "then start the installation again.",
            )
        }
    }

    companion object {
        const val PROVENANCE_FILE_NAME = "artifact-provenance.json"
    }
}

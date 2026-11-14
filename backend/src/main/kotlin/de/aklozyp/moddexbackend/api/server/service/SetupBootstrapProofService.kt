package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.stereotype.Service
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Duration
import java.util.HexFormat

/**
 * One-time local bootstrap proof that protects the initial administrator setup
 * (issue #265). While no administrator hash is installed, the backend keeps a
 * random proof in the configuration directory with owner-only permissions. A
 * remote setup request must supply the current proof; the proof is consumed
 * together with the first-admin commit under the settings monitor, expires
 * after a fixed lifetime, and is regenerated at every startup, so a proof from
 * an earlier session never works.
 *
 * The proof is only available locally: it is never logged, never returned by
 * any endpoint, and the proof file is not readable by other accounts on POSIX
 * systems.
 */
@Service
class SetupBootstrapProofService(
    private val directories: ModdexDirectories,
    private val objectMapper: ObjectMapper,
    private val logger: Logger,
) {
    private val random = SecureRandom()

    private val proofFile: Path
        get() = directories.configDir.resolve(PROOF_FILE_NAME)

    /**
     * Creates a fresh proof, replacing any earlier one. Returns the new token,
     * or null when the proof file could not be written; callers then fail
     * closed until the configuration directory is repaired and the backend is
     * restarted.
     */
    fun issueNewProof(): String? {
        val proof = SetupBootstrapProof(
            token = newToken(),
            createdAtEpochMillis = System.currentTimeMillis(),
        )
        return try {
            Files.createDirectories(proofFile.parent)
            writeProofAtomically(proof)
            restrictToOwnerOnly(proofFile)
            logger.info(
                "Created a one-time setup bootstrap proof at ${proofFile.toAbsolutePath()} " +
                    "(valid for ${PROOF_LIFETIME.toHours()} hours). " +
                    "Read the proof from that file on the server host to complete the initial setup."
            )
            proof.token
        } catch (e: Exception) {
            logger.warn(
                "Could not write the setup bootstrap proof file. Complete-setup requests are rejected " +
                    "until the configuration directory is writable and the backend is restarted. " +
                    "Check the directory permissions. Error: ${e.message}"
            )
            null
        }
    }

    /** True only when the submitted proof matches the current, unexpired proof. */
    fun validate(submittedProof: String?): Boolean {
        val submitted = submittedProof?.trim().takeUnless { it.isNullOrEmpty() } ?: return false
        val current = readCurrentProof()?.token ?: return false
        return MessageDigest.isEqual(
            submitted.toByteArray(Charsets.UTF_8),
            current.toByteArray(Charsets.UTF_8),
        )
    }

    /**
     * Consumes the proof. Best effort: a failed removal is logged and leaves
     * the endpoint protected by the installed-administrator check; the file is
     * replaced at the next startup.
     */
    fun consume() {
        try {
            Files.deleteIfExists(proofFile)
        } catch (e: Exception) {
            logger.warn(
                "Could not remove the used setup bootstrap proof file. The installed administrator " +
                    "check still protects setup; remove ${proofFile.toAbsolutePath()} manually if it remains. " +
                    "Error: ${e.message}"
            )
        }
    }

    /** Safe guidance for rejected setup requests; never includes the proof itself. */
    fun invalidProofMessage(): String =
        "Setup requires the current one-time bootstrap proof from the file $PROOF_FILE_NAME " +
            "in the backend configuration directory. Read that file on the server host, " +
            "enter its proof in the setup form, and retry. " +
            "If the file is missing or the proof is expired or already used, " +
            "restart the backend to generate a new proof."

    private fun readCurrentProof(): SetupBootstrapProof? {
        return try {
            val proof = Files.newInputStream(proofFile).use { input ->
                objectMapper.readValue(input, SetupBootstrapProof::class.java)
            }
            val age = System.currentTimeMillis() - proof.createdAtEpochMillis
            if (proof.token.isBlank() || age > PROOF_LIFETIME.toMillis()) {
                null
            } else {
                proof
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun writeProofAtomically(proof: SetupBootstrapProof) {
        val pendingFile = Files.createTempFile(proofFile.parent, ".$PROOF_FILE_NAME-", ".pending")
        try {
            Files.newOutputStream(pendingFile).use { output ->
                objectMapper.writeValue(output, proof)
            }
            Files.move(pendingFile, proofFile, ATOMIC_MOVE, REPLACE_EXISTING)
        } finally {
            try {
                Files.deleteIfExists(pendingFile)
            } catch (_: Exception) {
                logger.warn("Could not remove a pending bootstrap proof file. Check directory permissions.")
            }
        }
    }

    private fun restrictToOwnerOnly(path: Path) {
        try {
            Files.setPosixFilePermissions(path, setOf(OWNER_READ, OWNER_WRITE))
        } catch (_: UnsupportedOperationException) {
            logger.warn(
                "POSIX permissions are not supported on this platform; the setup bootstrap proof file " +
                    "could not be restricted to the service account. Restrict access to the configuration directory."
            )
        }
    }

    private fun newToken(): String {
        val bytes = ByteArray(TOKEN_BYTES)
        random.nextBytes(bytes)
        return HexFormat.of().formatHex(bytes)
    }

    data class SetupBootstrapProof(
        val token: String = "",
        val createdAtEpochMillis: Long = 0,
    )

    companion object {
        const val PROOF_FILE_NAME = "setup-bootstrap-token.json"
        val PROOF_LIFETIME: Duration = Duration.ofHours(24)
        private const val TOKEN_BYTES = 32
        private val OWNER_READ = java.nio.file.attribute.PosixFilePermission.OWNER_READ
        private val OWNER_WRITE = java.nio.file.attribute.PosixFilePermission.OWNER_WRITE
    }
}

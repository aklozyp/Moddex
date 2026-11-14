package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Component
import org.springframework.web.server.ResponseStatusException
import java.io.UncheckedIOException
import java.nio.file.Files
import java.nio.file.InvalidPathException
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.time.Instant

/**
 * The loader-specific start contract of one instance, resolved once at
 * installation time and stored in the instance directory. The start phase
 * reads this manifest instead of searching for a startable jar or an
 * installer argument file on every start.
 *
 * Paths are stored relative to the instance directory with forward slashes,
 * so the manifest stays valid when the instance directory is moved and never
 * leaks absolute host paths. Exactly one of [argsFile] and [jarPath] is set.
 *
 * Unknown properties are ignored, so older backends can read manifests
 * written by newer ones and the other way around.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
data class InstanceStartManifest(
    val loader: ModLoader? = null,
    val argsFile: String? = null,
    val jarPath: String? = null,
    val createdAt: String? = null,
)

/** One resolved start entry the command line can be built from. */
internal sealed interface StartEntry {
    /**
     * A Forge/NeoForge installer argument file (for example
     * `libraries/net/neoforged/neoforge/20.4.237/unix_args.txt`), relative to
     * the instance directory. Launching with `-jar` would ignore this contract.
     */
    data class ArgumentsFile(val relativePath: String) : StartEntry

    /** A startable server jar, relative to the instance directory. */
    data class ServerJar(val relativePath: String) : StartEntry
}

/**
 * Resolves the launch contract a completed installation leaves behind, so the
 * result can be stored as a start manifest instead of being guessed again on
 * every start. This is the same discovery the start phase used before start
 * manifests existed (#252); it stays the fallback for instances created
 * before manifests were stored.
 *
 * The decision is made once while the installation state is coherent and is
 * then frozen: after the installer has run, the argument file of the declared
 * loader wins over any jar; otherwise the startable jar is resolved with the
 * known priorities (fabric launch jar for Fabric, then `server.jar`, then a
 * leftover loader jar). Returns null when nothing is resolvable.
 */
internal object LoaderStartDiscovery {

    fun resolve(instance: Instance, directory: Path): StartEntry? {
        findLoaderArgsFile(instance, directory)?.let { return StartEntry.ArgumentsFile(it) }
        return findServerJar(instance, directory)?.let { StartEntry.ServerJar(it) }
    }

    /**
     * The installer writes a platform-specific argument file next to the
     * loader libraries; Windows launches use win_args.txt, everything
     * else uses unix_args.txt.
     */
    fun preferredArgsFileName(osName: String): String =
        if (osName.lowercase().contains("win")) "win_args.txt" else "unix_args.txt"

    /**
     * Finds the argument-file launch contract of a modern Forge or NeoForge
     * installation and returns it as a path relative to the instance directory,
     * so the command works from the instance working directory on every platform.
     * The installer writes Maven-style `libraries/net/<group>/<artifact>/<version>`
     * directories; the group of the declared loader is scanned first so leftovers
     * of another loader cannot win. Returns null when no installer-written
     * argument file exists (old loaders), falling back to the jar contract.
     */
    private fun findLoaderArgsFile(instance: Instance, directory: Path): String? {
        val preferred = preferredArgsFileName(System.getProperty("os.name"))
        val groups = when (instance.modLoader) {
            ModLoader.FORGE -> listOf("net/minecraftforge/forge", "net/neoforged/neoforge")
            ModLoader.NEOFORGE -> listOf("net/neoforged/neoforge", "net/minecraftforge/forge")
            else -> listOf("net/minecraftforge/forge", "net/neoforged/neoforge")
        }
        for (group in groups) {
            val groupDir = directory.resolve("libraries").resolve(group)
            if (!Files.isDirectory(groupDir)) continue
            val versionDirs = try {
                Files.list(groupDir).use { stream -> stream.filter { Files.isDirectory(it) }.toList() }
            } catch (_: UncheckedIOException) {
                // Unreadable group directory (e.g. removed during a concurrent
                // backup): fall back to the jar contract instead of failing.
                continue
            }
            val matches = versionDirs.mapNotNull { versionDir ->
                versionDir.resolve(preferred).takeIf { Files.isRegularFile(it) }
            }
            val chosen = chooseArgsFile(instance, matches) ?: continue
            return directory.relativize(chosen).toString().replace('\\', '/')
        }
        return null
    }

    private fun chooseArgsFile(instance: Instance, matches: List<Path>): Path? {
        if (matches.isEmpty()) return null
        instance.modLoaderVersion?.takeIf { it.isNotBlank() }?.let { version ->
            matches.firstOrNull { it.parent.fileName.toString() == version }?.let { return it }
            // The UI records the Forge build number only ("47.2.0") while the
            // library directory is "<gameVersion>-<build>" ("1.20.1-47.2.0").
            matches.firstOrNull { it.parent.fileName.toString().endsWith("-$version") }?.let { return it }
        }
        // Several leftover versions: the highest name approximates the newest
        // installed version.
        return matches.maxByOrNull { it.parent.fileName.toString() }
    }

    private fun findServerJar(instance: Instance, directory: Path): String? {
        // Priority 1: Loader specific
        if (instance.modLoader == ModLoader.FABRIC &&
            Files.exists(directory.resolve("fabric-server-launch.jar"))
        ) {
            return "fabric-server-launch.jar"
        }

        // Priority 2: Generic server.jar
        if (Files.exists(directory.resolve("server.jar"))) return "server.jar"

        // Priority 3: Find any likely jar
        val candidates = Files.list(directory).use {
            stream ->
            stream.filter { it.toString().endsWith(".jar") }
                .map { it.fileName.toString() }
                .toList()
        }

        // Forge often uses 'forge-1.x.x.jar'
        return candidates.firstOrNull { it.contains("forge") && !it.contains("installer") }
    }
}

/**
 * Persists the loader-specific start manifest of an instance in a dedicated
 * `start-manifest.json` file in the instance directory and turns it back into
 * a validated start entry when the instance is started. The file is written
 * atomically; nothing is mixed into `instance.json`.
 *
 * Transition rule: instances created before start manifests existed have no
 * `start-manifest.json`. [resolveForStart] reports them as absent (null) and
 * the start phase falls back to the legacy discovery with a logged migration
 * hint. A manifest that IS present but unreadable or invalid is never
 * silently bypassed: starting is rejected with guidance instead.
 */
@Component
class InstanceStartManifestStore(
    private val objectMapper: ObjectMapper,
    private val logger: Logger,
) {

    /**
     * Resolves the start entry the given instance must be started with.
     * Returns null when no start manifest is stored (instances created before
     * manifests existed); the caller then uses the legacy discovery. A stored
     * but unreadable, stale, or invalid manifest is rejected with guidance
     * naming a safe next action instead of falling back to guessing.
     */
    internal fun resolveForStart(instance: Instance, directory: Path): StartEntry? {
        val manifest = find(directory) ?: return null
        val declaredLoader = instance.modLoader ?: ModLoader.VANILLA
        if (manifest.loader != declaredLoader) {
            throw IllegalStateException(
                "The stored start manifest was created for loader " +
                    "${manifest.loader?.name ?: "unknown"} but the instance now declares ${declaredLoader.name}. " +
                    "Reinstall the instance so the start manifest is regenerated, then start again."
            )
        }

        val argsFile = manifest.argsFile
        val jarPath = manifest.jarPath
        if ((argsFile == null) == (jarPath == null)) {
            throw IllegalStateException(
                "The start manifest of this instance is invalid: it must reference exactly one start entry " +
                    "(an installer argument file or a server jar). " +
                    "Reinstall the instance so a valid start manifest is stored, then start again."
            )
        }

        if (argsFile != null) {
            val validated = validatedRelativePath(argsFile)
                ?: throw IllegalStateException(
                    "The start manifest of this instance contains an invalid argument file path. " +
                        "Reinstall the instance so a valid start manifest is stored, then start again."
                )
            if (!Files.isRegularFile(directory.resolve(validated))) {
                throw IllegalStateException(
                    "The start manifest references the argument file '$validated', which is missing in the " +
                        "instance directory. Restore it from a backup or reinstall the instance, then start again."
                )
            }
            return StartEntry.ArgumentsFile(validated)
        }

        val validatedJar = validatedRelativePath(jarPath!!)
            ?: throw IllegalStateException(
                "The start manifest of this instance contains an invalid server jar path. " +
                    "Reinstall the instance so a valid start manifest is stored, then start again."
            )
        if (!Files.isRegularFile(directory.resolve(validatedJar))) {
            throw IllegalStateException(
                "The start manifest references the server jar '$validatedJar', which is missing in the " +
                    "instance directory. Restore it from a backup or reinstall the instance, then start again."
            )
        }
        return StartEntry.ServerJar(validatedJar)
    }

    /**
     * Stores the start manifest for a freshly completed installation by
     * resolving the launch contract once. When nothing is resolvable (an
     * installation that produced no known start entry), no manifest is stored
     * and the instance keeps the legacy start behavior; when the manifest
     * cannot be written, the installation is not failed because the start
     * phase would fall back to the same legacy discovery. Both cases are
     * logged with guidance instead.
     */
    fun record(instance: Instance, directory: Path) {
        val entry = LoaderStartDiscovery.resolve(instance, directory)
        if (entry == null) {
            logger.warn(
                "No startable entry could be resolved for instance id=${instance.id} after installation; " +
                    "no $MANIFEST_FILE_NAME is stored and starting will use the legacy discovery. " +
                    "If the loader did not install as expected, check the installer output, then reinstall."
            )
            return
        }
        val manifest = InstanceStartManifest(
            loader = instance.modLoader ?: ModLoader.VANILLA,
            argsFile = (entry as? StartEntry.ArgumentsFile)?.relativePath,
            jarPath = (entry as? StartEntry.ServerJar)?.relativePath,
            createdAt = Instant.now().toString(),
        )
        val target = directory.resolve(MANIFEST_FILE_NAME)
        try {
            rejectSymbolicLink(target)
            writeJsonAtomically(target, objectMapper, manifest, logger) { pendingFile ->
                Files.move(pendingFile, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            }
            logger.info("Stored the start manifest ($MANIFEST_FILE_NAME) for instance id=${instance.id}")
        } catch (e: ResponseStatusException) {
            // A planted symbolic link is a trust-boundary problem the operator
            // must resolve deliberately; it is not degraded to the legacy path.
            throw e
        } catch (e: Exception) {
            logger.error(
                "Could not store the start manifest ($MANIFEST_FILE_NAME) for instance id=${instance.id}; " +
                    "starting will use the legacy discovery until the installation is re-run. " +
                    "Check the instance directory permissions, then reinstall to store the manifest."
            )
        }
    }

    /**
     * Reads the stored manifest. Returns null when no manifest is stored;
     * a manifest that exists but cannot be parsed is rejected with guidance —
     * its presence marks the instance as manifest-managed, so silently
     * guessing a start entry would hide a broken contract.
     */
    private fun find(directory: Path): InstanceStartManifest? {
        val file = directory.resolve(MANIFEST_FILE_NAME)
        if (!Files.isRegularFile(file)) return null
        return try {
            objectMapper.readValue(file.toFile(), InstanceStartManifest::class.java)
        } catch (e: Exception) {
            logger.error(
                "Could not read $MANIFEST_FILE_NAME in ${directory.toAbsolutePath()}: ${e.javaClass.simpleName}"
            )
            throw IllegalStateException(
                "The start manifest ($MANIFEST_FILE_NAME) of this instance exists but could not be read. " +
                    "Remove or repair the file in the instance directory and reinstall the instance, " +
                    "then start again."
            )
        }
    }

    /**
     * Manifest paths are relative to the instance directory and must never
     * escape it, even when the file was hand-edited: absolute paths, Windows
     * separators, and parent traversals are rejected instead of resolved.
     * The returned path is normalized and uses forward slashes.
     */
    private fun validatedRelativePath(raw: String): String? {
        if (raw.isBlank() || raw.contains('\\')) return null
        val candidate = try {
            Path.of(raw)
        } catch (_: InvalidPathException) {
            return null
        }
        if (candidate.isAbsolute) return null
        if (candidate.any { it.toString() == ".." }) return null
        val normalized = candidate.normalize().toString().replace('\\', '/')
        if (normalized.isBlank() || normalized == ".") return null
        return normalized
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
                "The start manifest file is a symbolic link. Remove it from the instance directory, " +
                    "then start the installation again.",
            )
        }
    }

    companion object {
        const val MANIFEST_FILE_NAME = "start-manifest.json"
    }
}

package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.model.mods.InstanceModList
import de.aklozyp.moddexbackend.model.mods.InstalledMod
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.stereotype.Service
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

data class ModpackArchive(
    val filename: String,
    val bytes: ByteArray,
    val contentType: String,
)

@Service
class ModpackExportService(
    private val objectMapper: ObjectMapper,
    private val instanceService: InstanceService,
    private val modListStore: InstanceModListStore,
    private val logger: Logger,
) {

    fun export(instanceId: UUID, format: ModpackFormat): ModpackArchive {
        val instance = instanceService.getInstanceById(instanceId)
        val instanceDir = instanceService.getInstancePath(instanceId)
        val modList = modListStore.load(instanceDir, instanceId)

        return when (format) {
            ModpackFormat.MODRINTH -> buildModrinthPack(instance, instanceDir, modList)
            ModpackFormat.CURSEFORGE -> buildCurseForgePack(instance, modList)
        }
    }

    private fun buildModrinthPack(instance: Instance, instanceDir: Path, modList: InstanceModList): ModpackArchive {
        val slug = slugify(instance.name ?: "moddex-pack")
        val filename = "$slug-modrinth.${ModpackFormat.MODRINTH.fileExtension}"

        val baos = ByteArrayOutputStream()
        ZipOutputStream(baos).use { zip ->
            val index = createModrinthIndex(instance, instanceDir, modList)
            val payload = objectMapper.writerWithDefaultPrettyPrinter().writeValueAsBytes(index)
            zip.putNextEntry(ZipEntry("modrinth.index.json"))
            zip.write(payload)
            zip.closeEntry()

            zip.putNextEntry(ZipEntry("overrides/README.txt"))
            zip.write("Place manual overrides in this directory.".toByteArray(StandardCharsets.UTF_8))
            zip.closeEntry()
        }

        return ModpackArchive(
            filename = filename,
            bytes = baos.toByteArray(),
            contentType = "application/zip",
        )
    }

    private fun buildCurseForgePack(instance: Instance, modList: InstanceModList): ModpackArchive {
        val validEntries = modList.mods.filter { mod ->
            mod.provider.name.equals("CURSEFORGE", ignoreCase = true)
                    && mod.projectId.toIntOrNull() != null
                    && mod.versionId.toIntOrNull() != null
        }


        val slug = slugify(instance.name ?: "moddex-pack")
        val filename = "$slug-curseforge.${ModpackFormat.CURSEFORGE.fileExtension}"

        val manifest = createCurseForgeManifest(instance, validEntries)

        val baos = ByteArrayOutputStream()
        ZipOutputStream(baos).use { zip ->
            val payload = objectMapper.writerWithDefaultPrettyPrinter().writeValueAsBytes(manifest)
            zip.putNextEntry(ZipEntry("manifest.json"))
            zip.write(payload)
            zip.closeEntry()

            zip.putNextEntry(ZipEntry("overrides/README.txt"))
            zip.write("Place manual overrides in this directory.".toByteArray(StandardCharsets.UTF_8))
            zip.closeEntry()
        }

        return ModpackArchive(
            filename = filename,
            bytes = baos.toByteArray(),
            contentType = "application/zip",
        )
    }

    private fun createModrinthIndex(instance: Instance, instanceDir: Path, modList: InstanceModList): Map<String, Any?> {
        val files = modList.mods.mapNotNull { mod ->
            val filename = (mod.fileName ?: buildFilename(mod)).takeIf { it.isNotBlank() }
            val download = mod.downloadUrl?.takeIf { it.isNotBlank() }
            val hashes = mutableMapOf<String, String>()
            mod.sha512?.takeIf { it.isNotBlank() }?.let { hashes["sha512"] = it }
            mod.sha1?.takeIf { it.isNotBlank() }?.let { hashes["sha1"] = it }
            if (filename == null || hashes.isEmpty()) {
                logger.warn("Skipping mod ${mod.projectId} due to missing filename or hashes for Modrinth export")
                return@mapNotNull null
            }

            val fileSize = resolveModFileSize(instanceDir, mod, filename)

            if (fileSize == null) {
                logger.warn("Skipping mod ${mod.projectId} due to missing file size for Modrinth export")
                return@mapNotNull null
            }

            val metadata = mutableMapOf<String, Any?>()
            metadata["project_id"] = mod.projectId
            mod.projectSlug?.let { metadata["project_slug"] = it }
            metadata["version_id"] = mod.versionId

            mutableMapOf<String, Any?>(
                "path" to "mods/$filename",
                "hashes" to hashes,
                "fileSize" to fileSize,
                "downloads" to listOfNotNull(download),
                "env" to mapOf("client" to "required", "server" to "required"),
            ).apply {
                put("metadata", metadata)
            }
        }

        val dependencies = mutableMapOf<String, String>()
        instance.gameVersion?.takeIf { it.isNotBlank() }?.let { dependencies["minecraft"] = it }
        resolveModrinthLoaderDependency(instance)?.let { (key, value) -> dependencies[key] = value }

        val versionId = UUID.randomUUID().toString()
        val packName = instance.name ?: "Moddex Pack"

        return mapOf(
            "formatVersion" to 1,
            "game" to "minecraft",
            "versionId" to versionId,
            "name" to packName,
            "summary" to "Exported from Moddex",
            "files" to files,
            "dependencies" to dependencies,
        )
    }

    private fun resolveModFileSize(instanceDir: Path, mod: InstalledMod, filename: String): Long? {
        mod.size?.takeIf { it > 0 }?.let { return it }

        val modsDir = instanceDir.resolve("mods")
        val filePath = modsDir.resolve(filename)
        return try {
            Files.size(filePath)
        } catch (ex: Exception) {
            logger.warn("Failed to determine file size for ${mod.projectId} at ${filePath.toAbsolutePath()}: ${ex.message}")
            null
        }
    }

    private fun createCurseForgeManifest(instance: Instance, mods: List<InstalledMod>): Map<String, Any?> {
        val loaderId = resolveCurseForgeLoaderId(instance)

        val files = mods.map { mod ->
            val projectId = mod.projectId.toInt()
            val fileId = mod.versionId.toInt()
            mapOf(
                "projectID" to projectId,
                "fileID" to fileId,
                "required" to true,
            )
        }

        val minecraft = mutableMapOf<String, Any?>(
            "version" to (instance.gameVersion ?: "Unknown"),
            "modLoaders" to listOf(
                mapOf(
                    "id" to loaderId,
                    "primary" to true,
                )
            )
        )

        val packName = instance.name ?: "Moddex Pack"
        val versionString = OffsetDateTime.now().format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

        return mapOf(
            "manifestType" to "minecraftModpack",
            "manifestVersion" to 1,
            "name" to packName,
            "version" to versionString,
            "author" to "Moddex",
            "overrides" to "overrides",
            "minecraft" to minecraft,
            "files" to files,
        )
    }

    private fun resolveCurseForgeLoaderId(instance: Instance): String {
        val loaderVersion = instance.modLoaderVersion ?: "latest"
        return when (instance.modLoader) {
            ModLoader.FORGE -> "forge-$loaderVersion"
            ModLoader.FABRIC -> "fabric-$loaderVersion"
            ModLoader.QUILT -> "quilt-$loaderVersion"
            ModLoader.NEOFORGE -> "neoforge-$loaderVersion"
            ModLoader.VANILLA, null -> "vanilla"
        }
    }

    private fun resolveModrinthLoaderDependency(instance: Instance): Pair<String, String>? {
        val version = instance.modLoaderVersion ?: return null
        return when (instance.modLoader) {
            ModLoader.FORGE -> "forge" to version
            ModLoader.NEOFORGE -> "neoforge" to version
            ModLoader.FABRIC -> "fabric-loader" to version
            ModLoader.QUILT -> "quilt-loader" to version
            ModLoader.VANILLA, null -> null
        }
    }

    private fun buildFilename(mod: InstalledMod): String {
        val slug = slugify(mod.projectSlug ?: mod.projectId)
        val preferredVersion = mod.versionNumber?.takeIf { it.isNotBlank() }
        val version = slugify(preferredVersion ?: mod.versionId)
        return "$slug-$version.jar"
    }

    private fun slugify(raw: String): String = raw
        .lowercase()
        .trim()
        .replace(Regex("[^a-z0-9-_]+"), "-")
        .trim('-')
        .ifBlank { "moddex" }
}

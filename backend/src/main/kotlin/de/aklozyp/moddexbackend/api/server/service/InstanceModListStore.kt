package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.model.mods.InstanceModList
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.stereotype.Service
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID

@Service
class InstanceModListStore(
    private val objectMapper: ObjectMapper,
    private val logger: Logger,
) {

    fun load(instanceDir: Path, instanceId: UUID): InstanceModList {
        val path = modListPath(instanceDir)
        if (!Files.exists(path)) {
            logger.info("modlist.json missing for instance id=$instanceId, creating default")
            return InstanceModList(instanceId = instanceId)
        }

        return runCatching {
            val loaded = objectMapper.readValue<InstanceModList>(path.toFile())
            if (loaded.instanceId != instanceId) {
                logger.warn("modlist.json instanceId mismatch: expected=$instanceId actual=${loaded.instanceId}")
                loaded.copy(instanceId = instanceId)
            } else {
                loaded
            }
        }.onFailure {
            logger.error("Failed to read modlist.json for instance id=$instanceId: ${it.message}")
        }.getOrElse {
            InstanceModList(instanceId = instanceId)
        }
    }

    fun ensure(instanceDir: Path, instanceId: UUID): InstanceModList {
        val current = load(instanceDir, instanceId)
        save(instanceDir, current)
        return current
    }

    fun save(instanceDir: Path, modList: InstanceModList) {
        val path = modListPath(instanceDir)
        try {
            Files.createDirectories(instanceDir)
            objectMapper.writerWithDefaultPrettyPrinter().writeValue(path.toFile(), modList)
            logger.debug("Persisted modlist.json for instance id=${modList.instanceId} at ${path.toAbsolutePath()}")
        } catch (ex: Exception) {
            logger.error("Failed to write modlist.json for instance id=${modList.instanceId}: ${ex.message}")
            throw ex
        }
    }

    fun modsDirectory(instanceDir: Path): Path {
        val modsDir = instanceDir.resolve(MODS_DIR_NAME)
        Files.createDirectories(modsDir)
        return modsDir
    }

    fun modListPath(instanceDir: Path): Path = instanceDir.resolve(MOD_LIST_FILE_NAME)

    companion object {
        const val MODS_DIR_NAME = "mods"
        private const val MOD_LIST_FILE_NAME = "modlist.json"
    }
}

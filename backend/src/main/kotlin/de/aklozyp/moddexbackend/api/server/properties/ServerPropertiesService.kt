package de.aklozyp.moddexbackend.api.server.properties

import de.aklozyp.moddexbackend.api.server.service.InstanceService
import de.aklozyp.moddexbackend.model.dto.ServerPropertiesDto
import de.aklozyp.moddexbackend.model.dto.ServerPropertiesUpdateRequest
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.context.annotation.Lazy
import org.springframework.core.io.ClassPathResource
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.UUID

@Service
class ServerPropertiesService(
    @Lazy private val instanceService: InstanceService,
    private val schemaProvider: ServerPropertiesSchemaProvider,
    private val logger: Logger,
) {
    private val mapper = ServerPropertiesMapper()
    private val templateResource = ClassPathResource(TEMPLATE_PATH)

    fun initializeForInstance(instanceId: UUID) {
        ensurePropertiesExists(instanceId)
    }

    fun loadProperties(instanceId: UUID): ServerPropertiesDto {
        val document = readDocument(instanceId, preferBackup = false)
        val schema = schemaProvider.get()
        val dto = mapper.toDto(document, schema)
        logger.info("Loaded server.properties for instance=$instanceId with ${dto.categories.sumOf { it.entries.size }} entries")
        return dto
    }

    fun loadBackupProperties(instanceId: UUID): ServerPropertiesDto {
        val document = readDocument(instanceId, preferBackup = true)
        val schema = schemaProvider.get()
        val dto = mapper.toDto(document, schema)
        logger.info("Loaded server.properties.old for instance=$instanceId")
        return dto
    }

    fun updateProperties(instanceId: UUID, request: ServerPropertiesUpdateRequest): ServerPropertiesDto {
        ensurePropertiesExists(instanceId)
        val directory = instanceService.getInstancePath(instanceId)
        val propertiesFile = directory.resolve(PROPERTIES_FILENAME)
        val backupFile = directory.resolve(PROPERTIES_BACKUP_FILENAME)

        if (!Files.exists(backupFile) && Files.exists(propertiesFile)) {
            Files.copy(propertiesFile, backupFile, StandardCopyOption.REPLACE_EXISTING)
            logger.info("Created server.properties.old backup for instance=$instanceId")
        }

        val document = ServerPropertiesDocument.parse(propertiesFile)
        val schema = schemaProvider.get()

        request.values.forEach { (key, value) ->
            val descriptor = schema.descriptorFor(key)
            val formatted = descriptor?.formatValue(value) ?: value?.toString() ?: ""
            document.setValue(key, formatted)
        }

        Files.writeString(propertiesFile, document.toText(), StandardCharsets.UTF_8)
        logger.info("Persisted server.properties for instance=$instanceId with ${request.values.size} updated entries")

        return mapper.toDto(document, schema)
    }

    fun resetProperties(instanceId: UUID): ServerPropertiesDto {
        val directory = instanceService.getInstancePath(instanceId)
        val backupFile = directory.resolve(PROPERTIES_BACKUP_FILENAME)
        if (!Files.exists(backupFile)) {
            logger.warn("Requested reset for instance=$instanceId but no server.properties.old present")
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "No backup server.properties available")
        }
        val propertiesFile = directory.resolve(PROPERTIES_FILENAME)
        Files.copy(backupFile, propertiesFile, StandardCopyOption.REPLACE_EXISTING)
        logger.info("Restored server.properties from backup for instance=$instanceId")
        return loadProperties(instanceId)
    }

    private fun readDocument(instanceId: UUID, preferBackup: Boolean): ServerPropertiesDocument {
        ensurePropertiesExists(instanceId)
        val directory = instanceService.getInstancePath(instanceId)
        val backupFile = directory.resolve(PROPERTIES_BACKUP_FILENAME)
        val primaryFile = directory.resolve(PROPERTIES_FILENAME)
        val target = if (preferBackup) {
            if (!Files.exists(backupFile)) {
                logger.warn("Requested backup properties for instance=$instanceId but no backup exists")
                throw ResponseStatusException(HttpStatus.NOT_FOUND, "No backup server.properties available")
            }
            backupFile
        } else {
            primaryFile
        }
        return ServerPropertiesDocument.parse(target)
    }

    private fun ensurePropertiesExists(instanceId: UUID) {
        val directory = instanceService.getInstancePath(instanceId)
        Files.createDirectories(directory)
        val propertiesFile = directory.resolve(PROPERTIES_FILENAME)
        if (!Files.exists(propertiesFile)) {
            templateResource.inputStream.use { input ->
                Files.copy(input, propertiesFile, StandardCopyOption.REPLACE_EXISTING)
            }
            logger.info("Initialized server.properties for instance=$instanceId at ${propertiesFile.toAbsolutePath()}")
        }
    }

    companion object {
        private const val TEMPLATE_PATH = "data/generated/server.properties"
        private const val PROPERTIES_FILENAME = "server.properties"
        private const val PROPERTIES_BACKUP_FILENAME = "server.properties.old"
    }
}

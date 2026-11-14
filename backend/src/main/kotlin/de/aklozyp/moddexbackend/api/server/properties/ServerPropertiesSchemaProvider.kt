package de.aklozyp.moddexbackend.api.server.properties

import com.fasterxml.jackson.databind.ObjectMapper
import de.aklozyp.moddexbackend.model.properties.ServerPropertiesSchema
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.core.io.ClassPathResource
import org.springframework.stereotype.Component

@Component
class ServerPropertiesSchemaProvider(
    private val objectMapper: ObjectMapper,
    private val logger: Logger
) {
    private val schema: ServerPropertiesSchema by lazy { loadSchema() }

    fun get(): ServerPropertiesSchema = schema

    private fun loadSchema(): ServerPropertiesSchema {
        return try {
            val resource = ClassPathResource("data/schema/server-properties-schema.json")
            resource.inputStream.use { input ->
                objectMapper.readValue(input, ServerPropertiesSchema::class.java)
            }.also {
                logger.info("Loaded server.properties schema with  entries")
            }
        } catch (ex: Exception) {
            logger.error("Failed to read server.properties schema: ")
            throw ex
        }
    }
}
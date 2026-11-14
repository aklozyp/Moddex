package de.aklozyp.moddexbackend.api.server.properties

import de.aklozyp.moddexbackend.model.dto.ServerPropertiesDto
import de.aklozyp.moddexbackend.model.dto.ServerPropertyCategoryDto
import de.aklozyp.moddexbackend.model.dto.ServerPropertyEntryDto
import de.aklozyp.moddexbackend.model.properties.ServerPropertiesSchema
import de.aklozyp.moddexbackend.model.properties.ServerPropertyType

class ServerPropertiesMapper {
    fun toDto(document: ServerPropertiesDocument, schema: ServerPropertiesSchema): ServerPropertiesDto {
        val descriptorByKey = schema.properties.associateBy { it.key }
        val existingValues = document.propertyLines().associate { it.key to it.value }

        val extras = document.propertyLines()
            .filter { descriptorByKey[it.key] == null }
            .map { line ->
                ServerPropertyEntryDto(
                    key = line.key,
                    labelKey = line.key,
                    helpKey = null,
                    type = ServerPropertyType.STRING,
                    value = line.value,
                    defaultValue = null,
                    enumValues = null,
                    min = null,
                    max = null,
                    minecraftVersion = null,
                    isExtra = true,
                    hasChanged = true
                )
            }

        val categories = schema.categoryOrder.mapNotNull { categoryId ->
            val descriptorEntries = schema.properties
                .filter { it.category == categoryId }
                .map { descriptor ->
                    val rawValue = existingValues[descriptor.key] ?: descriptor.defaultValue
                    val defaultRaw = descriptor.defaultValue ?: ""
                    val value = descriptor.parseValue(rawValue)
                    val defaultValue = descriptor.parseValue(descriptor.defaultValue)
                    val hasChanged = existingValues[descriptor.key]?.let { it != defaultRaw } ?: false

                    ServerPropertyEntryDto(
                        key = descriptor.key,
                        labelKey = descriptor.labelKey,
                        helpKey = descriptor.helpKey,
                        type = descriptor.type,
                        value = value,
                        defaultValue = defaultValue,
                        enumValues = descriptor.enumValues,
                        min = descriptor.min,
                        max = descriptor.max,
                        minecraftVersion = descriptor.minecraftVersion,
                        isExtra = false,
                        hasChanged = hasChanged
                    )
                }

            val categoryExtras = if (categoryId == "extras") extras else emptyList()
            val allEntries = descriptorEntries + categoryExtras

            if (allEntries.isEmpty() && categoryId == "extras") {
                null
            } else {
                val categorySchema = schema.categories[categoryId]
                ServerPropertyCategoryDto(
                    id = categoryId,
                    labelKey = categorySchema?.labelKey ?: categoryId,
                    descriptionKey = categorySchema?.descriptionKey,
                    entries = allEntries,
                    isOther = categoryId == "extras"
                )
            }
        }

        return ServerPropertiesDto(categories = categories)
    }
}
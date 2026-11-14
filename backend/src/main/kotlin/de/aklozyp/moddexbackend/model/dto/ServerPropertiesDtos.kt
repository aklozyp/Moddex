package de.aklozyp.moddexbackend.model.dto

import de.aklozyp.moddexbackend.model.properties.ServerPropertyType

data class ServerPropertiesDto(
    val categories: List<ServerPropertyCategoryDto>
)

data class ServerPropertyCategoryDto(
    val id: String,
    val labelKey: String,
    val descriptionKey: String? = null,
    val entries: List<ServerPropertyEntryDto>,
    val isOther: Boolean = false
)

data class ServerPropertyEntryDto(
    val key: String,
    val labelKey: String,
    val helpKey: String? = null,
    val type: ServerPropertyType,
    val value: Any?,
    val defaultValue: Any?,
    val enumValues: List<String>? = null,
    val min: Int? = null,
    val max: Int? = null,
    val minecraftVersion: String? = null,
    val isExtra: Boolean = false,
    val hasChanged: Boolean = false
)

data class ServerPropertiesUpdateRequest(
    val values: Map<String, Any?>
)

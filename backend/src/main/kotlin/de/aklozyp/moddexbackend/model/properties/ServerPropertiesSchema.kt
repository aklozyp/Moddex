package de.aklozyp.moddexbackend.model.properties

data class ServerPropertiesSchema(
    val categoryOrder: List<String>,
    val categories: Map<String, ServerPropertyCategorySchema>,
    val properties: List<ServerPropertySchemaEntry>
) {
    fun descriptorFor(key: String): ServerPropertySchemaEntry? = properties.firstOrNull { it.key == key }
}

data class ServerPropertyCategorySchema(
    val labelKey: String,
    val descriptionKey: String? = null
)

data class ServerPropertySchemaEntry(
    val key: String,
    val type: ServerPropertyType,
    val defaultValue: String? = null,
    val min: Int? = null,
    val max: Int? = null,
    val enumValues: List<String>? = null,
    val category: String,
    val labelKey: String,
    val helpKey: String? = null,
    val minecraftVersion: String? = null
) {
    fun parseValue(raw: String?): Any? = when (type) {
        ServerPropertyType.STRING -> raw ?: defaultValue ?: ""
        ServerPropertyType.ENUM -> raw ?: defaultValue ?: ""
        ServerPropertyType.INTEGER -> {
            val candidate = (raw ?: defaultValue)?.trim()
            candidate?.toLongOrNull()?.toInt() ?: 0
        }
        ServerPropertyType.BOOLEAN -> (raw ?: defaultValue)?.trim()?.equals("true", ignoreCase = true) ?: false
    }

    fun formatValue(value: Any?): String = when (type) {
        ServerPropertyType.STRING, ServerPropertyType.ENUM -> value?.toString() ?: ""
        ServerPropertyType.INTEGER -> when (value) {
            is Number -> value.toLong().toString()
            is String -> value.trim()
            else -> defaultValue ?: "0"
        }
        ServerPropertyType.BOOLEAN -> when (value) {
            is Boolean -> value
            is String -> value.equals("true", ignoreCase = true)
            else -> (defaultValue ?: "false").equals("true", ignoreCase = true)
        }.toString()
    }
}
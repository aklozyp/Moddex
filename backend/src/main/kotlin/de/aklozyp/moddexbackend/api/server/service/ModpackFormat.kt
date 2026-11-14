package de.aklozyp.moddexbackend.api.server.service

enum class ModpackFormat(val fileExtension: String) {
    MODRINTH("mrpack"),
    CURSEFORGE("zip");

    companion object {
        fun from(raw: String?): ModpackFormat {
            val normalized = raw?.trim()?.lowercase()
            return when (normalized) {
                "modrinth", null, "mrpack" -> MODRINTH
                "curseforge", "cf" -> CURSEFORGE
                else -> throw IllegalArgumentException("Unsupported modpack format: $raw")
            }
        }
    }
}

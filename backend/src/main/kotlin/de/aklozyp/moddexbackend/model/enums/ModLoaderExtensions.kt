package de.aklozyp.moddexbackend.model.enums

fun ModLoader.toModrinthLoaderId(): String? = when (this) {
    ModLoader.VANILLA -> null
    ModLoader.FORGE -> "forge"
    ModLoader.NEOFORGE -> "neoforge"
    ModLoader.FABRIC -> "fabric"
    ModLoader.QUILT -> "quilt"
}

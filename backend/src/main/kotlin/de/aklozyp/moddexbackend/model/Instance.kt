package de.aklozyp.moddexbackend.model

import de.aklozyp.moddexbackend.model.enums.ModLoader
import java.util.UUID

data class Instance(
    var id: UUID? = null,
    var name: String? = null,
    var description: String? = null,
    var gameVersion: String? = null,
    var modLoader: ModLoader? = null,
    var modLoaderVersion: String? = null,
    var javaXmx: String? = null,
    var javaXms: String? = null,
    var javaPath: String? = null,
)

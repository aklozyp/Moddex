package de.aklozyp.moddexbackend.model.dto

import de.aklozyp.moddexbackend.model.enums.ModDataProvider

data class ModrinthProjectDetailsResponse(
    val project: ModrinthProject,
    val versions: List<ModrinthVersion>,
    val provider: ModDataProvider = ModDataProvider.MODRINTH,
)

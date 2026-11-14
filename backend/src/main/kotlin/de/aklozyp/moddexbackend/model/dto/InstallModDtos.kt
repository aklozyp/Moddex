package de.aklozyp.moddexbackend.model.dto

import de.aklozyp.moddexbackend.model.enums.ModDataProvider
import de.aklozyp.moddexbackend.model.mods.InstalledMod

data class InstallModRequest(
    val projectId: String,
    val versionId: String? = null,
    val provider: ModDataProvider? = null,
)

data class InstallModResponse(
    val installed: List<InstalledMod>
)


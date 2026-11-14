package de.aklozyp.moddexbackend.model.mods

import de.aklozyp.moddexbackend.model.enums.ModDataProvider
import java.util.UUID

data class InstanceModList(
    val schemaVersion: Int = 1,
    val instanceId: UUID,
    val mods: MutableList<InstalledMod> = mutableListOf()
)

data class InstalledMod(
    val projectId: String,
    val projectSlug: String?,
    val versionId: String,
    val versionNumber: String,
    val fileName: String?,
    val displayName: String?,
    val downloadUrl: String?,
    val sha1: String?,
    val sha512: String?,
    val size: Long?,
    val installedAt: String,
    val dependencies: List<String> = emptyList(),
    val provider: ModDataProvider = ModDataProvider.MODRINTH,
    val downloaded: Boolean = true,
    val clientSideOnly: Boolean = false,
)

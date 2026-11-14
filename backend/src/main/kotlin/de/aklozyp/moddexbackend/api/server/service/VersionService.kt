package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.api.loader.*
import de.aklozyp.moddexbackend.api.modrinth.ModrinthService
import de.aklozyp.moddexbackend.model.dto.MojangVersionDetail
import de.aklozyp.moddexbackend.services.CompatibilityService
import org.springframework.stereotype.Service

@Service
class VersionService(
    private val mojang: MojangService,
    private val modrinth: ModrinthService,
    private val compat: CompatibilityService,
    private val fabric: FabricMetaService,
    private val quilt: QuiltMetaService,
    private val forge: ForgeMetaService,
    private val neo: NeoForgeService,
) {
    fun minecraftVersions(): List<String> = mojang.allMinecraftVersions()

    fun minecraftServerUrl(mcVersion: String): String = minecraftServerDownload(mcVersion)?.url ?: ""

    fun minecraftServerDownload(mcVersion: String): MojangVersionDetail.Download? = mojang.serverJarDownload(mcVersion)

    fun compatibleLoaders(mcVersion: String): List<CompatibilityService.LoaderSupport> =
        compat.compatibleLoaders(mcVersion)

    fun loaderVersions(loader: String, mc: String?): Any = when (loader.lowercase()) {
        "fabric" -> mc?.let { fabric.fabricLoaderFor(it).map { li -> li.version } } ?: emptyList<String>()
        "quilt" -> mc?.let { quilt.quiltLoaderVersionsFor(it) } ?: emptyList<String>()
        "forge" -> mc?.let { forge.forgeVersionsFor(it) } ?: emptyList<String>()
        "neoforge" -> mapOf("hint" to "Gib die konkrete NeoForge-Version an; kompatible Sets variieren je MC.")
        else -> emptyList<String>()
    }

    fun loaderDownloadUrl(loader: String, version: String, mc: String?): String = when (loader.lowercase()) {
        "fabric" -> fabric.fabricLoaderDownloadUrl(version)
        "quilt" -> quilt.quiltLoaderDownloadUrl(version)
        "forge" -> {
            require(!mc.isNullOrBlank()) { "mc Parameter (z.B. 1.21.1) ist für Forge erforderlich" }
            forge.forgeInstallerUrl(mc, version)
        }
        "neoforge" -> neo.neoForgeInstallerUrl(version)
        else -> ""
    }

    // Modrinth passthroughs
    fun modrinthLoaders() = modrinth.listLoaders()
    fun modrinthGameVersions() = modrinth.listGameVersions()
}

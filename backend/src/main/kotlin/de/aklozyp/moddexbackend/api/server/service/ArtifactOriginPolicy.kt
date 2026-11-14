package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.model.enums.ModLoader
import org.springframework.stereotype.Component

/**
 * Pins the canonical HTTPS hosts each installer artifact may be downloaded
 * from. The downloader rejects every origin outside these sets, including
 * redirects, so a tampered version manifest cannot silently move a download
 * to a foreign host.
 */
@Component
class ArtifactOriginPolicy(
    val installerHostsByLoader: Map<ModLoader, Set<String>> = PRODUCTION_INSTALLER_HOSTS,
    val vanillaServerHosts: Set<String> = PRODUCTION_VANILLA_SERVER_HOSTS,
) {

    fun installerHosts(loader: ModLoader): Set<String> =
        installerHostsByLoader[loader] ?: PRODUCTION_INSTALLER_HOSTS.getValue(loader)

    companion object {
        val PRODUCTION_VANILLA_SERVER_HOSTS = setOf("piston-data.mojang.com", "launcher.mojang.com")
        val PRODUCTION_INSTALLER_HOSTS = mapOf(
            ModLoader.VANILLA to PRODUCTION_VANILLA_SERVER_HOSTS,
            ModLoader.FORGE to setOf("maven.minecraftforge.net"),
            ModLoader.NEOFORGE to setOf("maven.neoforged.net"),
            ModLoader.FABRIC to setOf("maven.fabricmc.net"),
            ModLoader.QUILT to setOf("maven.quiltmc.org"),
        )
    }
}

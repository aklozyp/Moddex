package de.aklozyp.moddexbackend.api.loader

import de.aklozyp.moddexbackend.model.dto.MojangVersionDetail
import de.aklozyp.moddexbackend.model.dto.VersionManifestV2
import org.springframework.stereotype.Service
import org.springframework.web.reactive.function.client.WebClient

@Service
class MojangService(private val client: WebClient) {
    private val manifestUrl = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"

    fun allMinecraftVersions(): List<String> {
        val manifest = client.get().uri(manifestUrl)
            .retrieve().bodyToMono(VersionManifestV2::class.java).block()
        return manifest?.versions?.map { it.id } ?: emptyList()
    }

    fun serverJarUrl(mcVersion: String): String? = serverJarDownload(mcVersion)?.url

    /**
     * Resolves the official server download including its published SHA-1
     * checksum and size from the Mojang version manifest, so callers can
     * verify the downloaded jar before using it.
     */
    fun serverJarDownload(mcVersion: String): MojangVersionDetail.Download? {
        val manifest = client.get().uri(manifestUrl)
            .retrieve().bodyToMono(VersionManifestV2::class.java).block() ?: return null
        val entry = manifest.versions.firstOrNull { it.id == mcVersion } ?: return null
        val detail = client.get().uri(entry.url)
            .retrieve().bodyToMono(MojangVersionDetail::class.java).block()
        return detail?.downloads?.server
    }
}

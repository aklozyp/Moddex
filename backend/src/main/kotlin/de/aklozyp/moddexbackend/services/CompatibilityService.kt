package de.aklozyp.moddexbackend.services

import de.aklozyp.moddexbackend.api.loader.FabricMetaService
import de.aklozyp.moddexbackend.api.loader.ForgeMetaService
import de.aklozyp.moddexbackend.api.loader.QuiltMetaService
import org.springframework.stereotype.Service

@Service
class CompatibilityService(
    private val fabric: FabricMetaService,
    private val quilt: QuiltMetaService,
    private val forge: ForgeMetaService,
) {
    data class LoaderSupport(
        val loader: String,
        val versions: List<String> // passende Loader-Versionen zur MC-Version
    )

    fun compatibleLoaders(mcVersion: String): List<LoaderSupport> {
        val out = mutableListOf<LoaderSupport>()

        // Fabric
        runCatching { fabric.fabricLoaderFor(mcVersion) }
            .getOrDefault(emptyList())
            .map { it.version }
            .let { if (it.isNotEmpty()) out += LoaderSupport("fabric", it) }

        // Quilt
        runCatching { quilt.quiltLoaderVersionsFor(mcVersion) }
            .getOrDefault(emptyList())
            .let { if (it.isNotEmpty()) out += LoaderSupport("quilt", it) }

        // Forge
        runCatching { forge.forgeVersionsFor(mcVersion) }
            .getOrDefault(emptyList())
            .let { if (it.isNotEmpty()) out += LoaderSupport("forge", it) }

        // NeoForge – keine MC→Version-Index-API einfach verfügbar; Nutzer kann Version angeben.
        // (Optional: man kann MMP/Maven-Metadaten scrapen oder Community-Listen nutzen.)
        return out
    }
}

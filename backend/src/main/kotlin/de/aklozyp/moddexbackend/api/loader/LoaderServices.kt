package de.aklozyp.moddexbackend.api.loader

import de.aklozyp.moddexbackend.model.dto.FabricLoaderMeta
import org.springframework.stereotype.Service
import org.springframework.web.reactive.function.client.WebClient

@Service
class FabricMetaService(private val client: WebClient) {
    private val base = "https://meta.fabricmc.net/v2"

    fun fabricLoaderFor(mcVersion: String): List<FabricLoaderMeta.LoaderInfo> {
        val list = client.get().uri("$base/versions/loader/$mcVersion")
            .retrieve().bodyToFlux(FabricLoaderMeta::class.java).collectList().block() ?: emptyList()
        return list.map { it.loader }
    }

    fun fabricLoaderDownloadUrl(loaderVersion: String): String =
        "https://maven.fabricmc.net/net/fabricmc/fabric-loader/$loaderVersion/fabric-loader-$loaderVersion.jar"
}

@Service
class QuiltMetaService(private val client: WebClient) {
    private val base = "https://meta.quiltmc.org/v3"

    fun quiltLoaderVersionsFor(mcVersion: String): List<String> {
        val arr = client.get().uri("$base/versions/loader/$mcVersion")
            .retrieve().bodyToMono(List::class.java).block() ?: emptyList<Any>()
        @Suppress("UNCHECKED_CAST")
        return arr.mapNotNull { (it as? Map<*, *>)?.get("loader") as? Map<*, *> }
            .mapNotNull { it["version"] as? String }
    }

    fun quiltLoaderDownloadUrl(loaderVersion: String): String =
        "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-loader/$loaderVersion/quilt-loader-$loaderVersion.jar"
}

@Service
class ForgeMetaService(private val client: WebClient) {
    private val promotions = "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"

    data class ForgePromotions(val promos: Map<String, String>?) // key: "<mc>-latest"/"<mc>-recommended" -> forgeVersion

    fun forgeVersionsFor(mcVersion: String): List<String> {
        val p = client.get().uri(promotions).retrieve().bodyToMono(ForgePromotions::class.java).block()
        val prefix = "$mcVersion-"
        return p?.promos?.filterKeys { it.startsWith(prefix) }?.values?.distinct()?.sorted() ?: emptyList()
    }


    fun forgeInstallerUrl(mcVersion: String, forgeBuild: String): String {
        val coord = "$mcVersion-$forgeBuild"
        return "https://maven.minecraftforge.net/net/minecraftforge/forge/$coord/forge-$coord-installer.jar"
    }
}

@Service
class NeoForgeService {
    fun neoForgeInstallerUrl(neoVersion: String): String =
        "https://maven.neoforged.net/releases/net/neoforged/neoforge/$neoVersion/neoforge-$neoVersion-installer.jar"
}

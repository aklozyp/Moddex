package de.aklozyp.moddexbackend.api.modrinth

import de.aklozyp.moddexbackend.model.dto.ModrinthCategoryTag
import de.aklozyp.moddexbackend.model.dto.ModrinthGameVersionTag
import de.aklozyp.moddexbackend.model.dto.ModrinthLoaderTag
import de.aklozyp.moddexbackend.model.dto.ModrinthProject
import de.aklozyp.moddexbackend.model.dto.ModrinthSearchResponse
import de.aklozyp.moddexbackend.model.dto.ModrinthVersion
import org.springframework.stereotype.Service
import org.springframework.web.reactive.function.client.WebClient
import org.springframework.web.util.UriComponentsBuilder
import java.util.Locale

@Service
class ModrinthService(
    private val client: WebClient
) {
    private val api = "https://api.modrinth.com/v2"

    fun listLoaders(): List<ModrinthLoaderTag> =
        client.get().uri("$api/tag/loader").retrieve()
            .bodyToFlux(ModrinthLoaderTag::class.java).collectList().block() ?: emptyList()

    fun listGameVersions(): List<ModrinthGameVersionTag> =
        client.get().uri("$api/tag/game_version").retrieve()
            .bodyToFlux(ModrinthGameVersionTag::class.java).collectList().block() ?: emptyList()

    fun listCategories(): List<ModrinthCategoryTag> =
        client.get().uri("$api/tag/category").retrieve()
            .bodyToFlux(ModrinthCategoryTag::class.java).collectList().block() ?: emptyList()

    fun searchMods(
        query: String?,
        loader: String?,
        gameVersion: String?,
        categories: Collection<String>,
        limit: Int,
        offset: Int,
        index: String = "relevance"
    ): ModrinthSearchResponse {
        val clampedLimit = limit.coerceIn(1, 100)
        val clampedOffset = offset.coerceAtLeast(0)
        val builder = UriComponentsBuilder.fromUriString("$api/search")
            .queryParam("index", index)
            .queryParam("limit", clampedLimit)
            .queryParam("offset", clampedOffset)

        if (!query.isNullOrBlank()) {
            builder.queryParam("query", query)
        }

        buildFacets(loader, gameVersion, categories)?.let { facets ->
            builder.queryParam("facets", facets)
        }

        val uri = builder.build().encode().toUri()
        return client.get().uri(uri).retrieve()
            .bodyToMono(ModrinthSearchResponse::class.java)
            .block() ?: ModrinthSearchResponse(emptyList(), clampedOffset, clampedLimit, 0)
    }

    fun recommendedMods(
        loader: String?,
        gameVersion: String?,
        categories: Collection<String>,
        limit: Int
    ): ModrinthSearchResponse =
        searchMods(
            query = null,
            loader = loader,
            gameVersion = gameVersion,
            categories = categories,
            limit = limit,
            offset = 0,
            index = "relevance"
        )

    fun getProject(projectIdOrSlug: String): ModrinthProject =
        client.get().uri("$api/project/{id}", projectIdOrSlug).retrieve()
            .bodyToMono(ModrinthProject::class.java)
            .block() ?: throw IllegalStateException("Project $projectIdOrSlug not found on Modrinth")

    fun getProjectVersions(
        projectIdOrSlug: String,
        loader: String?,
        gameVersion: String?
    ): List<ModrinthVersion> {
        val versions = client.get().uri("$api/project/{id}/version", projectIdOrSlug).retrieve()
            .bodyToFlux(ModrinthVersion::class.java)
            .collectList()
            .block()
            ?: emptyList()

        val normalizedLoader = loader?.lowercase(Locale.ROOT)
        val normalizedVersion = gameVersion?.lowercase(Locale.ROOT)

        return versions.filter { version ->
            val loaderMatches = normalizedLoader == null || version.loaders.any { it.equals(normalizedLoader, ignoreCase = true) }
            val versionMatches = normalizedVersion == null || version.game_versions.any { it.equals(normalizedVersion, ignoreCase = true) }
            loaderMatches && versionMatches
        }.sortedByDescending { it.date_published ?: "" }
    }

    fun getVersion(versionId: String): ModrinthVersion =
        client.get().uri("$api/version/{id}", versionId).retrieve()
            .bodyToMono(ModrinthVersion::class.java)
            .block() ?: throw IllegalStateException("Version $versionId not found on Modrinth")

    private fun buildFacets(
        loader: String?,
        gameVersion: String?,
        categories: Collection<String>
    ): String? {
        val facets = mutableListOf(listOf("project_type:mod"))

        loader?.takeIf { it.isNotBlank() }?.let {
            facets += listOf("categories:${it.lowercase(Locale.ROOT)}")
        }
        gameVersion?.takeIf { it.isNotBlank() }?.let {
            facets += listOf("versions:${it.lowercase(Locale.ROOT)}")
        }
        categories.mapNotNull { it.takeIf { value -> value.isNotBlank() } }
            .map { it.lowercase(Locale.ROOT) }
            .distinct()
            .forEach { category -> facets += listOf("categories:$category") }

        if (facets.isEmpty()) {
            return null
        }

        return facets.joinToString(prefix = "[[", postfix = "]]", separator = "],[") {
            "\"${it.joinToString(separator = "\",\"")}\""
        }
    }
}

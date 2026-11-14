package de.aklozyp.moddexbackend.model.dto

import de.aklozyp.moddexbackend.model.enums.ModDataProvider

data class ModrinthTag(
    val name: String,
    val icon: String?,
    val project_types: List<String>?
)

typealias ModrinthLoaderTag = ModrinthTag

data class ModrinthGameVersionTag(
    val version: String,
    val version_type: String?,
    val date: String?
)

data class ModrinthCategoryTag(
    val name: String,
    val project_type: String,
    val icon: String?,
    val header: String?
)

data class ModrinthSearchResponse(
    val hits: List<ModrinthSearchHit>,
    val offset: Int,
    val limit: Int,
    val total_hits: Int
)

data class ModrinthSearchHit(
    val project_id: String,
    val project_type: String,
    val slug: String,
    val author: String?,
    val title: String,
    val description: String?,
    val categories: List<String>?,
    val display_categories: List<String>?,
    val versions: List<String>?,
    val downloads: Long?,
    val follows: Long?,
    val icon_url: String?,
    val date_created: String?,
    val date_modified: String?,
    val latest_version: String?,
    val license: String?,
    val client_side: String?,
    val server_side: String?,
    val gallery: List<String>?,
    val featured_gallery: String?,
    val color: Int?,
    val provider: ModDataProvider = ModDataProvider.MODRINTH,
)

data class ModrinthProject(
    val id: String,
    val project_type: String,
    val slug: String,
    val title: String,
    val description: String?,
    val body: String?,
    val body_url: String?,
    val categories: List<String>?,
    val issues_url: String?,
    val source_url: String?,
    val wiki_url: String?,
    val discord_url: String?,
    val game_versions: List<String>?,
    val icon_url: String?,
    val client_side: String?,
    val server_side: String?,
    val provider: ModDataProvider = ModDataProvider.MODRINTH,
)

data class ModrinthVersion(
    val id: String,
    val project_id: String,
    val name: String?,
    val version_number: String,
    val game_versions: List<String>,
    val loaders: List<String>,
    val date_published: String?,
    val version_type: String?,
    val files: List<ModrinthFile>,
    val dependencies: List<ModrinthDependency>,
    val provider: ModDataProvider = ModDataProvider.MODRINTH,
)

data class ModrinthFile(
    val url: String,
    val filename: String,
    val primary: Boolean?,
    val size: Long?,
    val file_type: String?,
    val hashes: Map<String, String>?
)

data class ModrinthDependency(
    val project_id: String?,
    val version_id: String?,
    val file_name: String?,
    val dependency_type: String
)

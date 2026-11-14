package de.aklozyp.moddexbackend.api.curseforge

import com.fasterxml.jackson.annotation.JsonIgnoreProperties

data class CurseForgePagination(
    val index: Int,
    val pageSize: Int,
    val resultCount: Int,
    val totalCount: Int,
)

data class CurseForgePagedResponse<T>(
    val data: List<T>,
    val pagination: CurseForgePagination?,
)

data class CurseForgeResponse<T>(
    val data: T,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeMod(
    val id: Long,
    val name: String,
    val slug: String?,
    val summary: String?,
    val downloadCount: Long?,
    val gamePopularityRank: Int?,
    val authors: List<CurseForgeAuthor>?,
    val logo: CurseForgeAsset?,
    val categories: List<CurseForgeCategory>?,
    val screenshots: List<CurseForgeAsset>?,
    val latestFiles: List<CurseForgeFile>?,
    val latestFilesIndexes: List<CurseForgeFileIndex>?,
    val dateCreated: String?,
    val dateModified: String?,
    val dateReleased: String?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeAuthor(
    val name: String?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeAsset(
    val url: String?,
    val thumbnailUrl: String?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeCategory(
    val id: Int,
    val name: String?,
    val slug: String?,
    val classId: Int?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeFile(
    val id: Long,
    val displayName: String?,
    val fileName: String?,
    val downloadUrl: String?,
    val gameVersions: List<String>?,
    val fileLength: Long?,
    val releaseType: Int?,
    val fileDate: String?,
    val isServerPack: Boolean?,
    val serverPackFileId: Long?,
    val modules: List<CurseForgeFileModule>?,
    val hashes: List<CurseForgeHash>?,
    val dependencies: List<CurseForgeDependency>?,
    val alternateFileId: Long?,
    val isAlternate: Boolean?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeFileIndex(
    val fileId: Long?,
    val filename: String?,
    val gameVersion: String?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeFileModule(
    val name: String?,
    val fingerprint: Long?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeDependency(
    val modId: Long?,
    val fileId: Long?,
    val relationType: Int?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeHash(
    val value: String?,
    val algo: Int?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeGameVersionGroup(
    val name: String?,
    val versions: List<CurseForgeGameVersion>?,
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CurseForgeGameVersion(
    val name: String?,
)

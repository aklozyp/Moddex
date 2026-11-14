package de.aklozyp.moddexbackend.model.dto

data class ModrinthFiltersResponse(
    val loaders: List<ModrinthLoaderTag>,
    val gameVersions: List<ModrinthGameVersionTag>,
    val categories: List<ModrinthCategoryTag>
)

package de.aklozyp.moddexbackend.model.dto

data class FileEntry(
    val name: String,
    val isDirectory: Boolean,
    val size: Long,
    val lastModified: Long
)

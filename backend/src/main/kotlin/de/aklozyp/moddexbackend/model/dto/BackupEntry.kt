package de.aklozyp.moddexbackend.model.dto

data class BackupEntry(
    val name: String,
    val size: Long,
    val timestamp: Long
)

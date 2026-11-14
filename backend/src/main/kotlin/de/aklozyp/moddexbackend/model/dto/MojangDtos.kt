package de.aklozyp.moddexbackend.model.dto

data class VersionManifestV2(
    val latest: Latest,
    val versions: List<McVersionEntry>
) {
    data class Latest(val release: String?, val snapshot: String?)
    data class McVersionEntry(val id: String, val type: String, val url: String)
}

data class MojangVersionDetail(
    val downloads: Downloads?
) {
    data class Downloads(val server: Download?)
    data class Download(val url: String, val sha1: String?, val size: Long?)
}
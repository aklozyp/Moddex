package de.aklozyp.moddexbackend.model

class ServerSettings {
    var id: String? = null
    var projectPath: String? = null
    var defaultJavaXmx: String? = null
    var defaultJavaXms: String? = null
    var modProvider: de.aklozyp.moddexbackend.model.enums.ModDataProvider? = null
    var curseForgeApiKey: String? = null
    var adminPasswordHash: String? = null

    /**
     * Persistent revision of the administrator credential. It is incremented under the
     * settings write lock whenever the installed password hash changes and is embedded
     * into freshly issued JWTs, so tokens issued before a password change are rejected.
     * `null` means no revision was recorded yet (settings written by an older version);
     * enforcement starts with the next credential change.
     */
    var passwordRevision: Long? = null
}

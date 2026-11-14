package de.aklozyp.moddexbackend.api.server.service

/**
 * Thrown when an instance directory could not be removed completely. [remainingPaths]
 * lists the entries that are still present, relative to the instance directory;
 * [instanceDirectory] names that directory inside the instances root, so the
 * remainder stays locatable without server logs.
 */
class InstanceDeletionException(
    val remainingPaths: List<String>,
    val instanceDirectory: String,
) : RuntimeException(
    "The instance could not be fully deleted: ${remainingPaths.size} file(s) or folder(s) remain " +
        "under instance directory '$instanceDirectory'. Close programs using these files or check " +
        "the directory permissions, then retry the deletion or remove the remaining files manually."
)

package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.databind.ObjectMapper
import de.aklozyp.moddexbackend.services.Logger
import java.nio.file.Files
import java.nio.file.Path

internal fun writeJsonAtomically(
    target: Path,
    objectMapper: ObjectMapper,
    value: Any,
    logger: Logger,
    replaceFile: (Path) -> Unit,
) {
    val pendingFile = Files.createTempFile(target.parent, ".${target.fileName}-", ".pending")
    try {
        Files.newOutputStream(pendingFile).use { output ->
            objectMapper.writerWithDefaultPrettyPrinter().writeValue(output, value)
        }
        replaceFile(pendingFile)
    } finally {
        try {
            Files.deleteIfExists(pendingFile)
        } catch (_: Exception) {
            logger.warn("Could not remove a pending configuration file. Check directory permissions.")
        }
    }
}

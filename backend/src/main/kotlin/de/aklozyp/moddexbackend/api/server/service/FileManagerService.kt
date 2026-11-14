package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.model.dto.FileEntry
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import kotlin.io.path.isDirectory
import kotlin.io.path.isRegularFile
import kotlin.io.path.name
import kotlin.io.path.fileSize
import kotlin.io.path.getLastModifiedTime

@Service
class FileManagerService(
    private val instanceService: InstanceService,
    private val logger: Logger
) {

    fun listFiles(instanceId: UUID, path: String): List<FileEntry> {
        val root = instanceService.getInstancePath(instanceId)
        val target = resolvePath(root, path)

        if (!Files.exists(target) || !Files.isDirectory(target)) {
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "Directory not found")
        }

        return Files.list(target).map {
            FileEntry(
                name = it.name,
                isDirectory = it.isDirectory(),
                size = if (it.isRegularFile()) it.fileSize() else 0,
                lastModified = it.getLastModifiedTime().toMillis()
            )
        }.toList().sortedWith(compareBy({ !it.isDirectory }, { it.name }))
    }

    fun readFile(instanceId: UUID, path: String): String {
        val root = instanceService.getInstancePath(instanceId)
        val target = resolvePath(root, path)

        if (!Files.exists(target) || !Files.isRegularFile(target)) {
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "File not found")
        }
        
        // Safety check for size? For now, assume reasonable text files.
        if (Files.size(target) > 1024 * 1024 * 5) { // 5MB limit
             throw ResponseStatusException(HttpStatus.BAD_REQUEST, "File too large to edit")
        }

        return Files.readString(target)
    }

    fun saveFile(instanceId: UUID, path: String, content: String) {
        val root = instanceService.getInstancePath(instanceId)
        val target = resolvePath(root, path)
        
        try {
            Files.writeString(target, content)
        } catch(e: Exception) {
            logger.error("Failed to save file $path for instance $instanceId: ${e.message}")
            throw ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "Failed to save file")
        }
    }

    fun deleteFile(instanceId: UUID, path: String) {
        val root = instanceService.getInstancePath(instanceId)
        val target = resolvePath(root, path)

        if (!Files.exists(target)) return
        
        try {
            if (Files.isDirectory(target)) {
                target.toFile().deleteRecursively()
            } else {
                Files.delete(target)
            }
        } catch(e: Exception) {
             logger.error("Failed to delete $path for instance $instanceId: ${e.message}")
             throw ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "Failed to delete item")
        }
    }

    private fun resolvePath(root: Path, path: String): Path {
        // Prevent directory traversal
        val safePath = path.replace("..", "")
        val resolved = if (safePath.isBlank() || safePath == "/") root else root.resolve(safePath)
        
        if (!resolved.normalize().startsWith(root.normalize())) {
            throw ResponseStatusException(HttpStatus.FORBIDDEN, "Invalid path")
        }
        return resolved
    }
}

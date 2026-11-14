package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.FileManagerService
import de.aklozyp.moddexbackend.model.dto.FileEntry
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*
import java.util.UUID

@RequestMapping("api/v1/instance/{id}/files")
@RestController
class FileManagerController(
    private val fileManagerService: FileManagerService
) {

    @GetMapping("/list")
    fun listFiles(
        @PathVariable id: UUID,
        @RequestParam(required = false, defaultValue = "") path: String
    ): List<FileEntry> {
        return fileManagerService.listFiles(id, path)
    }

    @GetMapping("/content")
    fun getFileContent(
        @PathVariable id: UUID,
        @RequestParam path: String
    ): ResponseEntity<String> {
        val content = fileManagerService.readFile(id, path)
        return ResponseEntity.ok(content)
    }

    @PostMapping("/content")
    fun saveFileContent(
        @PathVariable id: UUID,
        @RequestParam path: String,
        @RequestBody content: String
    ): ResponseEntity<Map<String, String>> {
        fileManagerService.saveFile(id, path, content)
        return ResponseEntity.ok(mapOf("message" to "Saved"))
    }

    @DeleteMapping
    fun deleteFile(
        @PathVariable id: UUID,
        @RequestParam path: String
    ): ResponseEntity<Map<String, String>> {
        fileManagerService.deleteFile(id, path)
        return ResponseEntity.ok(mapOf("message" to "Deleted"))
    }
}

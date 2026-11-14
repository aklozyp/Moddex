package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.BackupService
import de.aklozyp.moddexbackend.model.dto.BackupEntry
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*
import java.util.UUID

@RequestMapping("api/v1/instance/{id}/backups")
@RestController
class BackupController(
    private val backupService: BackupService
) {

    @GetMapping
    fun listBackups(@PathVariable id: UUID): List<BackupEntry> {
        return backupService.listBackups(id)
    }

    @PostMapping
    fun createBackup(@PathVariable id: UUID): BackupEntry {
        return backupService.createBackup(id)
    }

    @DeleteMapping("/{name}")
    fun deleteBackup(@PathVariable id: UUID, @PathVariable name: String): ResponseEntity<Map<String, String>> {
        backupService.deleteBackup(id, name)
        return ResponseEntity.ok(mapOf("message" to "Deleted"))
    }

    @PostMapping("/{name}/restore")
    fun restoreBackup(@PathVariable id: UUID, @PathVariable name: String): ResponseEntity<Map<String, String>> {
        backupService.restoreBackup(id, name)
        return ResponseEntity.ok(mapOf("message" to "Restored"))
    }
}

package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.services.Logger
import org.springframework.stereotype.Service
import java.nio.file.Files
import java.util.UUID

@Service
class EulaService(
    private val instanceService: InstanceService,
    private val logger: Logger
) {

    fun isEulaAccepted(instanceId: UUID): Boolean {
        val dir = instanceService.getInstancePath(instanceId)
        val eulaFile = dir.resolve("eula.txt")

        if (!Files.exists(eulaFile)) {
            // If file doesn't exist, it's not accepted. 
            // Often it's generated on first run, but we can pre-generate it if the user accepts.
            return false
        }

        return try {
            Files.readAllLines(eulaFile).any { line ->
                val trimmed = line.trim()
                !trimmed.startsWith("#") && trimmed.equals("eula=true", ignoreCase = true)
            }
        } catch (e: Exception) {
            logger.error("Failed to read eula.txt for instance $instanceId: ${e.message}")
            false
        }
    }

    fun acceptEula(instanceId: UUID) {
        val dir = instanceService.getInstancePath(instanceId)
        val eulaFile = dir.resolve("eula.txt")

        val content = """
            #By changing the setting below to TRUE you are indicating your agreement to our EULA (https://account.mojang.com/documents/minecraft_eula).
            #${java.time.Instant.now()}
            eula=true
        """.trimIndent()

        try {
            Files.writeString(eulaFile, content)
            logger.info("EULA accepted for instance $instanceId")
        } catch (e: Exception) {
            logger.error("Failed to write eula.txt for instance $instanceId: ${e.message}")
            throw RuntimeException("Failed to accept EULA: ${e.message}")
        }
    }
}

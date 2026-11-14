package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.services.Logger
import org.springframework.stereotype.Service
import java.util.UUID

/**
 * Deletes an instance in coordination with the process manager, so a running
 * game server can never write into world paths that are being removed.
 *
 * Deletion of an active instance is blocked instead of stopping it
 * automatically: the normal stop is asynchronous, world saving cannot be
 * confirmed here, and an automatic stop must not silently turn into a
 * force-kill. The user stops the instance in the console and retries.
 *
 * Between the running check and the actual deletion the process manager holds
 * a deletion reservation that rejects concurrent starts for this instance,
 * closing the window in which a start could spawn a new process into the
 * directory that is about to be removed. The reservation is released in every
 * path, so a failed deletion leaves the instance startable again.
 */
@Service
class InstanceDeletionService(
    private val instanceService: InstanceService,
    private val processManagerService: ProcessManagerService,
    private val logger: Logger,
) {
    fun deleteInstanceById(id: UUID) {
        if (!processManagerService.beginDeletion(id)) {
            logger.warn("Deletion of instance id=$id blocked; the instance is running, starting, or already being deleted")
            throw InstanceStillRunningException()
        }
        try {
            instanceService.deleteInstanceById(id)
        } finally {
            processManagerService.endDeletion(id)
        }
    }
}

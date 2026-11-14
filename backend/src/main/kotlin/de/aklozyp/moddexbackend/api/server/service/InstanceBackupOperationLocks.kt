package de.aklozyp.moddexbackend.api.server.service

import org.springframework.http.HttpStatus
import org.springframework.stereotype.Component
import org.springframework.web.server.ResponseStatusException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock

/**
 * Shared synchronization point for the backup lifecycle operations of one
 * instance: backup creation, restore and retention must not run concurrently
 * on the same instance, so no operation deletes or rewrites files another
 * operation is reading and none publishes or consumes a half-finished backup.
 *
 * Locks are held per instance id, so operations on different instances do not
 * block each other. A colliding attempt fails immediately with HTTP 409
 * instead of queueing behind the running operation; the caller can safely
 * retry once the running operation has finished. Locks are released when the
 * guarded operation returns, including on failures.
 */
@Component
class InstanceBackupOperationLocks {

    private val locks = ConcurrentHashMap<UUID, ReentrantLock>()

    /**
     * Runs [block] while holding the instance's backup operation lock, or
     * fails fast with HTTP 409 when another backup, restore or retention
     * operation is currently running for the same instance.
     */
    fun <T> withLock(instanceId: UUID, block: () -> T): T {
        val lock = locks.computeIfAbsent(instanceId) { ReentrantLock() }
        if (!lock.tryLock()) {
            throw ResponseStatusException(
                HttpStatus.CONFLICT,
                "Another backup, restore or retention operation is already running for this instance. " +
                    "Wait for it to finish and try again."
            )
        }
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }
}

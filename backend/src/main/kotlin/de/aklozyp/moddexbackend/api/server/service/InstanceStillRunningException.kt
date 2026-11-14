package de.aklozyp.moddexbackend.api.server.service

/**
 * Thrown when an instance deletion was blocked because the game-server
 * process is still running or starting, its termination could not be
 * verified, or a deletion is already in progress. No instance data was
 * changed; the deletion can be retried after the instance has stopped.
 */
class InstanceStillRunningException : RuntimeException(
    "The instance cannot be deleted while it is running, starting, or already being deleted. " +
        "Stop the instance in the console and wait until its status reports STOPPED, " +
        "then retry the deletion. No instance data was changed.",
)

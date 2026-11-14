package de.aklozyp.moddexbackend.api.server.service

/**
 * The installed credential changed between verification and commit. The password
 * change is refused instead of overwriting a credential the caller never saw.
 */
class ConcurrentPasswordChangeException : RuntimeException(
    "The administrator password changed concurrently. The password change was not applied."
)

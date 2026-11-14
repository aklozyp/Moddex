package de.aklozyp.moddexbackend.api.server.service

/** No administrator credential is installed, so the password cannot be changed. */
class AdminPasswordMissingException : RuntimeException(
    "No administrator password is configured. Complete the initial setup first."
)

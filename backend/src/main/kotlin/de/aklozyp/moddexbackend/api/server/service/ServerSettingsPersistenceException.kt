package de.aklozyp.moddexbackend.api.server.service

class ServerSettingsPersistenceException : RuntimeException(
    "Setup settings could not be read or saved. Check the server configuration and directory permissions, then retry."
)

package de.aklozyp.moddexbackend.config

import java.nio.file.Path

interface ModdexDirectories {
    val configDir: Path
    val dataDir: Path
    val logsDir: Path
}

package de.aklozyp.moddexbackend.api.server.service

import org.springframework.stereotype.Component
import java.nio.file.Path

@Component
class ServerProcessLauncher {
    fun start(command: List<String>, directory: Path): Process =
        ProcessBuilder(command)
            .directory(directory.toFile())
            .redirectErrorStream(true)
            .start()
}

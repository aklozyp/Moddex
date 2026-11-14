package de.aklozyp.moddexbackend.config

import org.springframework.core.env.Environment
import org.springframework.stereotype.Component
import java.nio.file.Path
import java.nio.file.Paths

@Component
class ModdexPaths(
    private val environment: Environment,
) : ModdexDirectories {

    override val configDir: Path by lazy { Paths.get(resolveConfigDir()) }
    override val dataDir: Path by lazy { Paths.get(resolveDataDir()) }
    override val logsDir: Path by lazy { resolveLogsDir() }

    private fun resolveConfigDir(): String {
        return listOf(
            environment.getProperty("moddex.paths.config"),
            environment.getProperty("moddex.config-dir"),
            "/etc/moddex"
        ).firstOrNull { !it.isNullOrBlank() }!!.trim()
    }

    private fun resolveDataDir(): String {
        return listOf(
            environment.getProperty("moddex.paths.data"),
            environment.getProperty("moddex.data-dir"),
            environment.getProperty("moddex.root"),
            "/var/lib/moddex"
        ).firstOrNull { !it.isNullOrBlank() }!!.trim()
    }

    private fun resolveLogsDir(): Path {
        val explicit = listOf(
            environment.getProperty("moddex.paths.logs"),
            environment.getProperty("moddex.logs.dir")
        ).firstOrNull { !it.isNullOrBlank() }?.trim()

        return explicit?.let { Paths.get(it) } ?: dataDir.resolve("logs")
    }
}

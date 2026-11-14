package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.services.Logger
import org.springframework.stereotype.Service
import java.io.File
import java.util.concurrent.TimeUnit

@Service
class JavaVersionService(
    private val logger: Logger
) {

    fun detectJavaVersions(): List<String> {
        val javaInstalls = mutableSetOf<String>()

        // 1. Check JAVA_HOME
        System.getenv("JAVA_HOME")?.let {
            val bin = File(it, "bin/java" + if (isWindows()) ".exe" else "")
            if (bin.exists()) javaInstalls.add(bin.absolutePath)
        }

        // 2. Check PATH (simple heuristic)
        val pathEnv = System.getenv("PATH")
        pathEnv?.split(File.pathSeparator)?.forEach { pathEntry ->
            val bin = File(pathEntry, "java" + if (isWindows()) ".exe" else "")
            if (bin.exists()) {
                 javaInstalls.add(bin.absolutePath)
            }
        }
        
        // 3. Common Windows Locations
        if (isWindows()) {
             val programFiles = System.getenv("ProgramFiles")
             if (programFiles != null) {
                 scanJavaFolder(File(programFiles, "Java"), javaInstalls)
                 scanJavaFolder(File(programFiles, "Eclipse Adoptium"), javaInstalls)
                 scanJavaFolder(File(programFiles, "Microsoft"), javaInstalls) // Microsoft builds of OpenJDK
             }
        } else {
             // Common Linux Locations
             scanJavaFolder(File("/usr/lib/jvm"), javaInstalls)
        }

        return javaInstalls.toList().sorted()
    }

    private fun scanJavaFolder(root: File, target: MutableSet<String>) {
        if (!root.exists() || !root.isDirectory) return
        root.listFiles()?.forEach { dir ->
            if (dir.isDirectory) {
                val bin = File(dir, "bin/java" + if (isWindows()) ".exe" else "")
                if (bin.exists()) {
                    target.add(bin.absolutePath)
                }
            }
        }
    }

    private fun isWindows() = System.getProperty("os.name").lowercase().contains("win")
}

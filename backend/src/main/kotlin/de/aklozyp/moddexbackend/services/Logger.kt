package de.aklozyp.moddexbackend.services

import de.aklozyp.moddexbackend.config.ModdexDirectories
import jakarta.annotation.PostConstruct
import org.springframework.stereotype.Component
import java.io.File
import java.io.FileWriter
import java.io.PrintWriter
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

@Component
class Logger(
    private val directories: ModdexDirectories,
) {
    private val latestLogFileName = "latest.log"
    private lateinit var logDirectory: File
    private var latestLogFile: File? = null
    private var fileLoggingEnabled: Boolean = false
    private val dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS")
    private val fileNameDateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss")

    @PostConstruct
    fun init() {
        // Determine base/log directory from properties or env
        try {
            val baseDir = directories.dataDir.toFile()
            if (!baseDir.exists()) baseDir.mkdirs()

            logDirectory = directories.logsDir.toFile()
            if (!logDirectory.exists()) logDirectory.mkdirs()

            val llf = File(logDirectory, latestLogFileName)
            // Rotate old latest.log if exists
            if (llf.exists()) {
                val firstLine = llf.bufferedReader().useLines { it.firstOrNull() }
                val timestampString = firstLine?.substringBefore(" - ")
                val oldLogTimestamp: LocalDateTime? = try {
                    timestampString?.let { LocalDateTime.parse(it, dateTimeFormatter) }
                } catch (e: Exception) {
                    System.err.println("Warning: Could not parse timestamp from old latest.log. Using current time for rename. Error: ${e.message}")
                    null
                }
                val newFileName = oldLogTimestamp?.let { "${fileNameDateTimeFormatter.format(it)}.log" }
                    ?: "${fileNameDateTimeFormatter.format(LocalDateTime.now())}_unparsed.log"
                val renamedFile = File(logDirectory, newFileName)
                if (!llf.renameTo(renamedFile)) {
                    System.err.println("Warning: Could not rename old log file: ${latestLogFileName}")
                }
            }
            llf.createNewFile()
            latestLogFile = llf
            fileLoggingEnabled = true
            info("Logger initialized successfully. Writing logs to: ${llf.absolutePath}")
        } catch (e: Exception) {
            fileLoggingEnabled = false
            latestLogFile = null
            System.err.println("Logger file output disabled due to error: ${e.message}. Falling back to console only.")
        }
    }

    fun log(message: String, level: String = "INFO") {
        val timestamp = LocalDateTime.now().format(dateTimeFormatter)
        val formattedMessage = "$timestamp - $level - $message"

        // Print to console
        println(formattedMessage)

        if (fileLoggingEnabled) {
            try {
                latestLogFile?.let { f ->
                    PrintWriter(FileWriter(f, true)).use { out ->
                        out.println(formattedMessage)
                    }
                }
            } catch (e: Exception) {
                System.err.println("Error writing to log file: ${e.message}. Disabling file logging.")
                fileLoggingEnabled = false
            }
        }
    }

    // Convenience methods
    fun info(message: String) = log(message, "INFO")
    fun warn(message: String) = log(message, "WARN")
    fun error(message: String) = log(message, "ERROR")
    fun debug(message: String) = log(message, "DEBUG")
}

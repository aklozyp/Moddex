package de.aklozyp.moddexbackend.api.server.properties

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path

class ServerPropertiesDocument private constructor(
    private val lines: MutableList<Line>
) {
    sealed interface Line {
        fun render(): String
    }

    data class CommentLine(private val content: String) : Line {
        override fun render(): String = content
    }

    data class BlankLine(private val content: String = "") : Line {
        override fun render(): String = content
    }

    data class PropertyLine(
        val key: String,
        var value: String,
        private val prefix: String
    ) : Line {
        override fun render(): String = prefix + value
    }

    fun propertyLines(): List<PropertyLine> = lines.filterIsInstance<PropertyLine>()

    fun getValue(key: String): String? = propertyLines().firstOrNull { it.key == key }?.value

    fun setValue(key: String, newValue: String) {
        val existing = propertyLines().firstOrNull { it.key == key }
        if (existing != null) {
            existing.value = newValue
        } else {
            lines.add(PropertyLine(key, newValue, "$key="))
        }
    }

    fun toText(): String = lines.joinToString(System.lineSeparator()) { it.render() }

    companion object {
        fun parse(path: Path): ServerPropertiesDocument {
            val lines = if (Files.exists(path)) {
                Files.readAllLines(path, StandardCharsets.UTF_8)
            } else {
                emptyList()
            }
            return parse(lines)
        }

        fun parse(rawLines: List<String>): ServerPropertiesDocument {
            val parsed = rawLines.map { line ->
                when {
                    line.isBlank() -> BlankLine(line)
                    line.trimStart().startsWith('#') || line.trimStart().startsWith('!') -> CommentLine(line)
                    else -> {
                        val separatorIndex = findSeparatorIndex(line)
                        if (separatorIndex == -1) {
                            CommentLine(line)
                        } else {
                            val key = line.substring(0, separatorIndex).trim()
                            val prefix = line.substring(0, separatorIndex + 1)
                            val value = if (separatorIndex + 1 <= line.lastIndex) {
                                line.substring(separatorIndex + 1)
                            } else {
                                ""
                            }
                            PropertyLine(key, value, prefix)
                        }
                    }
                }
            }.toMutableList()
            return ServerPropertiesDocument(parsed)
        }

        private fun findSeparatorIndex(line: String): Int {
            var escaped = false
            line.forEachIndexed { index, char ->
                when {
                    escaped -> escaped = false
                    char == '\\' -> escaped = true
                    char == '=' || char == ':' -> return index
                }
            }
            return -1
        }
    }
}

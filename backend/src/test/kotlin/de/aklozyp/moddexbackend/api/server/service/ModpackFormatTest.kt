package de.aklozyp.moddexbackend.api.server.service

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class ModpackFormatTest {

    @Test
    fun `from accepts whitespace around format name`() {
        val format = ModpackFormat.from("  curseforge\n")
        assertEquals(ModpackFormat.CURSEFORGE, format)
    }

    @Test
    fun `from defaults to modrinth when null`() {
        assertEquals(ModpackFormat.MODRINTH, ModpackFormat.from(null))
    }
}


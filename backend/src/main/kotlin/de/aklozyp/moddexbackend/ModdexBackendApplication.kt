package de.aklozyp.moddexbackend

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication

@SpringBootApplication
class ModdexBackendApplication

fun main(args: Array<String>) {
    runApplication<ModdexBackendApplication>(*args)
}

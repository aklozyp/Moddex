package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.JavaVersionService
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("api/v1/java")
class JavaVersionController(
    private val javaVersionService: JavaVersionService
) {

    @GetMapping("/versions")
    fun getAvailableVersions(): List<String> {
        return javaVersionService.detectJavaVersions()
    }
}

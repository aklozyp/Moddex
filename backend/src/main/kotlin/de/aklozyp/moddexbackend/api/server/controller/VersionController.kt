package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.VersionService
import de.aklozyp.moddexbackend.services.CompatibilityService
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.web.bind.annotation.*
import org.springframework.web.server.ResponseStatusException

@RequestMapping("/api/v1/version")
@RestController
class VersionController(
    private val versionService: VersionService,
    private val logger: Logger,
) {
    @GetMapping("/minecraft/versions", produces = [MediaType.APPLICATION_JSON_VALUE])
    fun getMinecraftVersions(): List<String> {
        logger.info("GET /api/v1/version/minecraft/versions requested")
        val versions = versionService.minecraftVersions()
        logger.info("GET /api/v1/version/minecraft/versions returning ${versions.size} entries")
        return versions
    }

    @GetMapping("/minecraft/{mcVersion}/server-url", produces = [MediaType.TEXT_PLAIN_VALUE])
    fun getMinecraftServerUrl(@PathVariable mcVersion: String): String {
        logger.info("GET /api/v1/version/minecraft/$mcVersion/server-url requested")
        val url = versionService.minecraftServerUrl(mcVersion)
        logger.info("GET /api/v1/version/minecraft/$mcVersion/server-url returning ${if (url.isBlank()) "<empty>" else "URL"}")
        return url
    }

    @GetMapping("/modloaders/compatible/{mcVersion}", produces = [MediaType.APPLICATION_JSON_VALUE])
    fun getCompatibleLoaders(@PathVariable mcVersion: String): List<CompatibilityService.LoaderSupport> {
        logger.info("GET /api/v1/version/modloaders/compatible/$mcVersion requested")
        val loaders = versionService.compatibleLoaders(mcVersion)
        logger.info("GET /api/v1/version/modloaders/compatible/$mcVersion returning ${loaders.size} loaders")
        return loaders
    }

    @GetMapping("/modloaders/{loader}/versions", produces = [MediaType.APPLICATION_JSON_VALUE])
    fun getLoaderVersions(
        @PathVariable loader: String,
        @RequestParam(required = false, name = "mc") mc: String?
    ): Any {
        logger.info("GET /api/v1/version/modloaders/$loader/versions requested mc=$mc")
        if (loader.equals("forge", ignoreCase = true) && mc.isNullOrBlank()) {
            logger.warn("GET /api/v1/version/modloaders/$loader/versions missing mc parameter")
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "Parameter 'mc' ist fuer Forge erforderlich, z.B. mc=1.21.1")
        }
        val versions = versionService.loaderVersions(loader, mc)
        logger.info("GET /api/v1/version/modloaders/$loader/versions returning ${when (versions) {
            is Collection<*> -> versions.size
            is Map<*, *> -> versions.size
            else -> "result"
        }} entries")
        return versions
    }

    @GetMapping("/modloaders/{loader}/download", produces = [MediaType.TEXT_PLAIN_VALUE])
    fun getLoaderDownloadUrl(
        @PathVariable loader: String,
        @RequestParam("version") version: String,
        @RequestParam(required = false, name = "mc") mc: String?
    ): String {
        logger.info("GET /api/v1/version/modloaders/$loader/download requested version=$version mc=$mc")
        if (loader.equals("forge", ignoreCase = true) && mc.isNullOrBlank()) {
            logger.warn("GET /api/v1/version/modloaders/$loader/download missing mc parameter")
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "Parameter 'mc' ist fuer Forge erforderlich, z.B. mc=1.21.1")
        }
        val url = versionService.loaderDownloadUrl(loader, version, mc)
        logger.info("GET /api/v1/version/modloaders/$loader/download returning ${if (url.isBlank()) "<empty>" else "URL"}")
        return url
    }

    @GetMapping("/modrinth/loaders")
    fun modrinthLoaders(): Any {
        logger.info("GET /api/v1/version/modrinth/loaders requested")
        val loaders = versionService.modrinthLoaders()
        logger.info("GET /api/v1/version/modrinth/loaders returning ${if (loaders is Collection<*>) loaders.size else "result"}")
        return loaders
    }

    @GetMapping("/modrinth/game-versions")
    fun modrinthGameVersions(): Any {
        logger.info("GET /api/v1/version/modrinth/game-versions requested")
        val versions = versionService.modrinthGameVersions()
        logger.info("GET /api/v1/version/modrinth/game-versions returning ${if (versions is Collection<*>) versions.size else "result"}")
        return versions
    }
}

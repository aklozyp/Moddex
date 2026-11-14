package de.aklozyp.moddexbackend.api.server.controller

import de.aklozyp.moddexbackend.api.server.service.AdminPasswordMissingException
import de.aklozyp.moddexbackend.api.server.service.ConcurrentPasswordChangeException
import de.aklozyp.moddexbackend.api.server.service.JwtService
import de.aklozyp.moddexbackend.api.server.service.ServerSettingsPersistenceException
import de.aklozyp.moddexbackend.api.server.service.ServerSettingsService
import de.aklozyp.moddexbackend.services.Logger
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.security.crypto.password.PasswordEncoder
import org.springframework.web.bind.annotation.ExceptionHandler
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("api/v1/auth")
class AuthController(
    private val serverSettingsService: ServerSettingsService,
    private val passwordEncoder: PasswordEncoder,
    private val jwtService: JwtService,
    private val logger: Logger
) {

    @PostMapping("/login")
    fun login(@RequestBody request: LoginRequest): ResponseEntity<Any> {
        val settings = serverSettingsService.getServerSettings()

        if (settings.adminPasswordHash == null) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).body(mapOf("error" to "Setup required"))
        }

        if (passwordEncoder.matches(request.password, settings.adminPasswordHash)) {
            val token = jwtService.generateToken("admin")
            logger.info("Admin logged in")
            return ResponseEntity.ok(mapOf("token" to token))
        }

        logger.warn("Failed login attempt")
        return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(mapOf("error" to "Invalid credentials"))
    }

    /**
     * Changes the administrator password and revokes sessions issued before the change
     * (issue #267): the new credential and its revision are committed atomically under the
     * settings lock, and JWT validation rejects tokens pinned to an older revision. The
     * response intentionally contains no new token; clients sign in again.
     */
    @PostMapping("/change-password")
    fun changePassword(@RequestBody request: ChangePasswordRequest): ResponseEntity<Any> {
        if (request.newPassword.length < 8) {
            return ResponseEntity.badRequest()
                .body(mapOf("error" to "New password must be at least 8 characters"))
        }

        val currentHash = serverSettingsService.getInstalledAdminPasswordHash()
        if (currentHash.isNullOrBlank()) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).body(mapOf("error" to "Setup required"))
        }

        if (!passwordEncoder.matches(request.currentPassword, currentHash)) {
            logger.warn("Failed password change attempt")
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(
                mapOf("error" to "The current password is incorrect. Enter your current password and try again.")
            )
        }

        val newHash = passwordEncoder.encode(request.newPassword)
        return try {
            serverSettingsService.changeAdminPassword(currentHash, newHash)
            ResponseEntity.ok(mapOf("message" to "Password changed. Sign in again with the new password."))
        } catch (_: AdminPasswordMissingException) {
            ResponseEntity.status(HttpStatus.FORBIDDEN).body(mapOf("error" to "Setup required"))
        } catch (_: ConcurrentPasswordChangeException) {
            ResponseEntity.status(HttpStatus.CONFLICT).body(
                mapOf("error" to "The password was just changed. Enter the current password and try again.")
            )
        }
    }

    @ExceptionHandler(ServerSettingsPersistenceException::class)
    fun handlePersistenceFailure(exception: ServerSettingsPersistenceException): ResponseEntity<Any> {
        return ResponseEntity.internalServerError().body(mapOf("error" to exception.message))
    }

    data class LoginRequest(val password: String)
    data class ChangePasswordRequest(val currentPassword: String, val newPassword: String)
}

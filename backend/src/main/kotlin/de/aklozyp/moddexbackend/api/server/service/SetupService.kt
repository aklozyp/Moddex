package de.aklozyp.moddexbackend.api.server.service

import de.aklozyp.moddexbackend.services.Logger
import org.springframework.security.crypto.password.PasswordEncoder
import org.springframework.stereotype.Service

@Service
class SetupService(
    private val serverSettingsService: ServerSettingsService,
    private val passwordEncoder: PasswordEncoder,
    private val logger: Logger
) {

    fun isSetupRequired(): Boolean {
        return serverSettingsService.isInitialAdminPasswordMissing()
    }

    fun completeSetup(password: String, bootstrapProof: String?) {
        val passwordHash = passwordEncoder.encode(password)
        serverSettingsService.initializeAdminPassword(passwordHash, bootstrapProof)
        logger.info("Initial setup completed. Admin password set.")
    }
}

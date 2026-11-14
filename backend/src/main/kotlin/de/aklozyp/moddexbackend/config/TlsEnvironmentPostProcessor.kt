package de.aklozyp.moddexbackend.config

import org.springframework.boot.SpringApplication
import org.springframework.boot.env.EnvironmentPostProcessor
import org.springframework.core.env.ConfigurableEnvironment
import org.springframework.core.env.MapPropertySource
import java.nio.file.Files
import java.nio.file.Path

/**
 * Maps the documented MODDEX_TLS_* environment contract onto Spring Boot's
 * native server.ssl properties. TLS stays off unless MODDEX_TLS_ENABLED=true;
 * enabling it without usable key material fails fast with a safe next action
 * instead of silently falling back to plain HTTP. Passwords are forwarded to
 * the SSL configuration but never logged.
 */
class TlsEnvironmentPostProcessor : EnvironmentPostProcessor {

    override fun postProcessEnvironment(environment: ConfigurableEnvironment, application: SpringApplication) {
        val enabledRaw = environment.getProperty(ENABLED_VAR) ?: return
        val enabled = when (enabledRaw.trim().lowercase()) {
            "true" -> true
            "false" -> false
            else -> throw IllegalStateException(
                "$ENABLED_VAR must be true or false. Set it accordingly or remove the variable, then start the backend again.",
            )
        }
        if (!enabled) {
            return
        }

        val certificate = material(CERT_VAR, environment)
        val privateKey = material(KEY_VAR, environment)
        val keystore = material(KEYSTORE_VAR, environment)
        if ((certificate != null || privateKey != null) && keystore != null) {
            throw IllegalStateException(
                "Native TLS accepts either $CERT_VAR with $KEY_VAR or $KEYSTORE_VAR, not both. " +
                    "Set one variant only, then start the backend again.",
            )
        }
        val properties = when {
            certificate != null && privateKey != null -> {
                requireReadable(CERT_VAR, certificate)
                requireReadable(KEY_VAR, privateKey)
                buildMap {
                    put("server.ssl.enabled", "true")
                    put("server.ssl.certificate", certificate)
                    put("server.ssl.certificate-private-key", privateKey)
                }
            }

            keystore != null -> {
                requireReadable(KEYSTORE_VAR, keystore)
                buildMap {
                    put("server.ssl.enabled", "true")
                    put("server.ssl.key-store", keystore)
                    environment.getProperty(KEYSTORE_PASSWORD_VAR)?.let { put("server.ssl.key-store-password", it) }
                    put("server.ssl.key-store-type", environment.getProperty(KEYSTORE_TYPE_VAR, "PKCS12"))
                }
            }

            certificate != null || privateKey != null -> throw IllegalStateException(
                "Native TLS needs both $CERT_VAR (certificate chain) and $KEY_VAR (private key). " +
                    "Set both files, or use $KEYSTORE_VAR instead, then start the backend again.",
            )

            else -> throw IllegalStateException(
                "$ENABLED_VAR=true but no TLS key material is configured. Set $CERT_VAR and $KEY_VAR, " +
                    "or $KEYSTORE_VAR, then start the backend again.",
            )
        }
        environment.propertySources.addFirst(MapPropertySource(PROPERTY_SOURCE_NAME, properties))
    }

    private fun material(variable: String, environment: ConfigurableEnvironment): String? =
        environment.getProperty(variable)?.trim()?.takeIf { it.isNotEmpty() }

    private fun requireReadable(variable: String, value: String) {
        val path = Path.of(value)
        if (!Files.isRegularFile(path) || !Files.isReadable(path)) {
            throw IllegalStateException(
                "$variable points to '$value', which is not a readable file. Fix the path and grant the " +
                    "service account read permission, then start the backend again.",
            )
        }
    }

    companion object {
        const val ENABLED_VAR = "MODDEX_TLS_ENABLED"
        const val CERT_VAR = "MODDEX_TLS_CERT_FILE"
        const val KEY_VAR = "MODDEX_TLS_KEY_FILE"
        const val KEYSTORE_VAR = "MODDEX_TLS_KEYSTORE"
        const val KEYSTORE_PASSWORD_VAR = "MODDEX_TLS_KEYSTORE_PASSWORD"
        const val KEYSTORE_TYPE_VAR = "MODDEX_TLS_KEYSTORE_TYPE"
        const val PROPERTY_SOURCE_NAME = "moddexNativeTls"
    }
}

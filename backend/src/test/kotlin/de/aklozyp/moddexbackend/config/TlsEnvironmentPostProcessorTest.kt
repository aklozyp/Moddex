package de.aklozyp.moddexbackend.config

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import org.springframework.boot.SpringApplication
import org.springframework.core.env.MapPropertySource
import org.springframework.core.env.StandardEnvironment
import java.nio.file.Files
import java.nio.file.Path

class TlsEnvironmentPostProcessorTest {

    @TempDir
    lateinit var tempDir: Path

    private val processor = TlsEnvironmentPostProcessor()
    private val application = SpringApplication()

    private fun environment(vararg pairs: Pair<String, String>): StandardEnvironment {
        val env = StandardEnvironment()
        env.propertySources.addFirst(MapPropertySource("test", mapOf(*pairs)))
        return env
    }

    private fun writeMaterial(name: String): Path {
        val file = tempDir.resolve(name)
        Files.writeString(file, "fixture")
        return file
    }

    @Test
    fun tlsStaysOffWhenTheVariableIsUnset() {
        val environment = environment()

        processor.postProcessEnvironment(environment, application)

        assertThat(environment.propertySources.contains(TlsEnvironmentPostProcessor.PROPERTY_SOURCE_NAME)).isFalse()
    }

    @Test
    fun tlsStaysOffWhenExplicitlyDisabled() {
        val environment = environment(TlsEnvironmentPostProcessor.ENABLED_VAR to "false")

        processor.postProcessEnvironment(environment, application)

        assertThat(environment.propertySources.contains(TlsEnvironmentPostProcessor.PROPERTY_SOURCE_NAME)).isFalse()
    }

    @Test
    fun invalidEnabledValueFailsWithASafeNextAction() {
        val environment = environment(TlsEnvironmentPostProcessor.ENABLED_VAR to "yes")

        val exception = assertThrows<IllegalStateException> {
            processor.postProcessEnvironment(environment, application)
        }

        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.ENABLED_VAR)
        assertThat(exception.message).contains("true or false")
    }

    @Test
    fun enabledWithoutKeyMaterialNamesTheConfigurationOptions() {
        val environment = environment(TlsEnvironmentPostProcessor.ENABLED_VAR to "true")

        val exception = assertThrows<IllegalStateException> {
            processor.postProcessEnvironment(environment, application)
        }

        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.CERT_VAR)
        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.KEY_VAR)
        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.KEYSTORE_VAR)
    }

    @Test
    fun certificateWithoutKeyNamesBothVariables() {
        val environment = environment(
            TlsEnvironmentPostProcessor.ENABLED_VAR to "true",
            TlsEnvironmentPostProcessor.CERT_VAR to writeMaterial("server.crt").toString(),
        )

        val exception = assertThrows<IllegalStateException> {
            processor.postProcessEnvironment(environment, application)
        }

        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.CERT_VAR)
        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.KEY_VAR)
    }

    @Test
    fun pemPairIsMappedOntoTheNativeSslProperties() {
        val cert = writeMaterial("server.crt")
        val key = writeMaterial("server.key")
        val environment = environment(
            TlsEnvironmentPostProcessor.ENABLED_VAR to "true",
            TlsEnvironmentPostProcessor.CERT_VAR to cert.toString(),
            TlsEnvironmentPostProcessor.KEY_VAR to key.toString(),
        )

        processor.postProcessEnvironment(environment, application)

        assertThat(environment.getProperty("server.ssl.enabled")).isEqualTo("true")
        assertThat(environment.getProperty("server.ssl.certificate")).isEqualTo(cert.toString())
        assertThat(environment.getProperty("server.ssl.certificate-private-key")).isEqualTo(key.toString())
    }

    @Test
    fun keystoreIsMappedWithTypeAndPassword() {
        val keystore = writeMaterial("server.p12")
        val environment = environment(
            TlsEnvironmentPostProcessor.ENABLED_VAR to "true",
            TlsEnvironmentPostProcessor.KEYSTORE_VAR to keystore.toString(),
            TlsEnvironmentPostProcessor.KEYSTORE_PASSWORD_VAR to "not-a-real-secret",
            TlsEnvironmentPostProcessor.KEYSTORE_TYPE_VAR to "PKCS12",
        )

        processor.postProcessEnvironment(environment, application)

        assertThat(environment.getProperty("server.ssl.enabled")).isEqualTo("true")
        assertThat(environment.getProperty("server.ssl.key-store")).isEqualTo(keystore.toString())
        assertThat(environment.getProperty("server.ssl.key-store-type")).isEqualTo("PKCS12")
        // The password is forwarded to the SSL configuration, never logged.
        assertThat(environment.getProperty("server.ssl.key-store-password")).isEqualTo("not-a-real-secret")
    }

    @Test
    fun pemAndKeystoreTogetherAreRejected() {
        val environment = environment(
            TlsEnvironmentPostProcessor.ENABLED_VAR to "true",
            TlsEnvironmentPostProcessor.CERT_VAR to writeMaterial("server.crt").toString(),
            TlsEnvironmentPostProcessor.KEY_VAR to writeMaterial("server.key").toString(),
            TlsEnvironmentPostProcessor.KEYSTORE_VAR to writeMaterial("server.p12").toString(),
        )

        val exception = assertThrows<IllegalStateException> {
            processor.postProcessEnvironment(environment, application)
        }

        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.CERT_VAR)
        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.KEYSTORE_VAR)
        assertThat(exception.message).contains("not both")
    }

    @Test
    fun missingMaterialFileFailsWithTheVariableAndPath() {
        val environment = environment(
            TlsEnvironmentPostProcessor.ENABLED_VAR to "true",
            TlsEnvironmentPostProcessor.KEYSTORE_VAR to tempDir.resolve("absent.p12").toString(),
        )

        val exception = assertThrows<IllegalStateException> {
            processor.postProcessEnvironment(environment, application)
        }

        assertThat(exception.message).contains(TlsEnvironmentPostProcessor.KEYSTORE_VAR)
        assertThat(exception.message).contains("absent.p12")
        assertThat(exception.message).contains("read permission")
    }
}

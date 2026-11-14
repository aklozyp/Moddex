package de.aklozyp.moddexbackend.config

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.EnabledOnOs
import org.junit.jupiter.api.condition.OS
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.web.server.LocalServerPort
import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource
import java.net.URL
import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyStore
import java.security.SecureRandom
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

/**
 * Proves that a natively configured HTTPS backend starts with a valid
 * certificate and serves requests on the configured port. The MODDEX_TLS_*
 * to server.ssl mapping itself is covered by TlsEnvironmentPostProcessorTest.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@Tag("ci")
@EnabledOnOs(OS.LINUX, OS.MAC)
class NativeTlsStartTest {

    @LocalServerPort
    private var port: Int = 0

    @Test
    fun backendStartsNativelyOverHttpsAndServesTheSetupStatus() {
        val connection = URL("https://127.0.0.1:$port/api/v1/setup/status").openConnection() as HttpsURLConnection
        connection.sslSocketFactory = trustingTheTestCertificate().socketFactory
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000

        val status = connection.responseCode
        val body = connection.inputStream.bufferedReader().use { it.readText() }

        assertThat(status).isEqualTo(200)
        assertThat(body).contains("setupRequired")
    }

    private fun trustingTheTestCertificate(): SSLContext {
        val keyStore = KeyStore.getInstance("PKCS12")
        Files.newInputStream(KEYSTORE).use { keyStore.load(it, STORE_PASSWORD.toCharArray()) }
        val trustManagerFactory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        trustManagerFactory.init(keyStore)
        val context = SSLContext.getInstance("TLS")
        context.init(null, trustManagerFactory.trustManagers, SecureRandom())
        return context
    }

    companion object {
        private const val STORE_PASSWORD = "moddex-it-keystore"
        private val STATE_DIR: Path = Files.createTempDirectory("moddex-tls-it")
        private val KEYSTORE: Path = STATE_DIR.resolve("moddex-test.p12")

        init {
            val keytoolName = if (System.getProperty("os.name").lowercase().contains("win")) "keytool.exe" else "keytool"
            val keytool = Path.of(System.getProperty("java.home"), "bin", keytoolName)
            val process = ProcessBuilder(
                keytool.toString(),
                "-genkeypair",
                "-alias",
                "moddex-test",
                "-keyalg",
                "RSA",
                "-keysize",
                "2048",
                "-validity",
                "2",
                "-dname",
                "CN=localhost",
                "-ext",
                "SAN=dns:localhost,ip:127.0.0.1",
                "-keystore",
                KEYSTORE.toString(),
                "-storetype",
                "PKCS12",
                "-storepass",
                STORE_PASSWORD,
            ).redirectErrorStream(true).start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            check(process.waitFor() == 0) { "Test keystore generation failed: $output" }
        }

        @JvmStatic
        @DynamicPropertySource
        fun registerProperties(registry: DynamicPropertyRegistry) {
            registry.add("moddex.paths.config") { STATE_DIR.resolve("config").toString() }
            registry.add("moddex.paths.data") { STATE_DIR.resolve("data").toString() }
            registry.add("moddex.paths.logs") { STATE_DIR.resolve("logs").toString() }
            registry.add("server.address") { "127.0.0.1" }
            registry.add("server.ssl.enabled") { "true" }
            registry.add("server.ssl.key-store") { KEYSTORE.toString() }
            registry.add("server.ssl.key-store-password") { STORE_PASSWORD }
            registry.add("server.ssl.key-store-type") { "PKCS12" }
        }
    }
}

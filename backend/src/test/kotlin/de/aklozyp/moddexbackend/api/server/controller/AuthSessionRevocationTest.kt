package de.aklozyp.moddexbackend.api.server.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import de.aklozyp.moddexbackend.api.server.service.SetupBootstrapProofService
import de.aklozyp.moddexbackend.model.ServerSettings
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.MethodOrderer
import org.junit.jupiter.api.Order
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestMethodOrder
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.web.server.LocalServerPort
import org.springframework.test.context.DynamicPropertyRegistry
import org.springframework.test.context.DynamicPropertySource
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.file.Files
import java.nio.file.Path

/**
 * End-to-end contract for session revocation on password change (issue #267) over real HTTP,
 * including the security filter chain: setup completes with the current local bootstrap
 * proof (issue #265), a token issued before the change is rejected on protected routes with
 * a guided 401, a new login works, a failed change revokes nothing, and the revocation is
 * audited without secrets. Tests run as one ordered narrative because they share the backend
 * state directory.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@TestMethodOrder(MethodOrderer.OrderAnnotation::class)
class AuthSessionRevocationTest {
    @LocalServerPort
    var port: Int = 0

    @Autowired
    lateinit var objectMapper: com.fasterxml.jackson.databind.ObjectMapper

    private val client: HttpClient = HttpClient.newHttpClient()

    private val baseUrl: String
        get() = "http://127.0.0.1:$port"

    @Test
    @Order(1)
    fun setupInstallsCredentialWithRevisionAndLoginIssuesWorkingToken() {
        // The backend keeps a one-time bootstrap proof locally (issue #265); read it from
        // the configured configuration directory like a local operator would.
        val proof = currentBootstrapProof()

        val (rejectedStatus, rejectedBody) = post(
            "/api/v1/setup/complete",
            body = mapOf("password" to INITIAL_PASSWORD, "bootstrapToken" to "not-the-issued-proof"),
            token = null,
        )
        assertThat(rejectedStatus).isEqualTo(403)
        assertThat(rejectedBody).doesNotContain(proof)

        val (setupStatus, _) = post(
            "/api/v1/setup/complete",
            body = mapOf("password" to INITIAL_PASSWORD, "bootstrapToken" to proof),
            token = null,
        )
        assertThat(setupStatus).isEqualTo(200)
        assertThat(proofFile).doesNotExist()
        bootstrapToken = proof

        val persisted = jacksonObjectMapper().readValue<ServerSettings>(settingsFile.toFile())
        assertThat(persisted.adminPasswordHash).isNotBlank()
        assertThat(persisted.passwordRevision).isEqualTo(1L)

        val (status, body) = login(INITIAL_PASSWORD)
        assertThat(status).isEqualTo(200)
        tokenA = extractToken(body)

        val (protectedStatus, _) = get("/api/v1/serverSettings", tokenA)
        assertThat(protectedStatus).isEqualTo(200)
    }

    @Test
    @Order(2)
    fun passwordChangeRevokesPreviouslyIssuedTokenWithGuidedUnauthorized() {
        val (changeStatus, changeBody) = post(
            "/api/v1/auth/change-password",
            body = mapOf("currentPassword" to INITIAL_PASSWORD, "newPassword" to SECOND_PASSWORD),
            token = tokenA,
        )
        assertThat(changeStatus).isEqualTo(200)
        assertThat(changeBody).contains("Sign in again")

        val persisted = jacksonObjectMapper().readValue<ServerSettings>(settingsFile.toFile())
        assertThat(persisted.passwordRevision).isEqualTo(2L)

        val (revokedStatus, revokedBody) = get("/api/v1/serverSettings", tokenA)
        assertThat(revokedStatus).isEqualTo(401)
        assertThat(revokedBody).contains("Sign in again")
        assertThat(revokedBody).doesNotContain(tokenA)
    }

    @Test
    @Order(3)
    fun oldPasswordIsRejectedAndNewPasswordIssuesWorkingToken() {
        val (oldLoginStatus, oldLoginBody) = login(INITIAL_PASSWORD)
        assertThat(oldLoginStatus).isEqualTo(401)
        assertThat(oldLoginBody).contains("Invalid credentials")

        val (newLoginStatus, newLoginBody) = login(SECOND_PASSWORD)
        assertThat(newLoginStatus).isEqualTo(200)
        tokenB = extractToken(newLoginBody)

        val (protectedStatus, _) = get("/api/v1/serverSettings", tokenB)
        assertThat(protectedStatus).isEqualTo(200)
    }

    @Test
    @Order(4)
    fun failedChangeWithWrongCurrentPasswordRevokesNothing() {
        val revisionBefore = persistedRevision()

        val (failedStatus, failedBody) = post(
            "/api/v1/auth/change-password",
            body = mapOf("currentPassword" to WRONG_PASSWORD, "newPassword" to THIRD_PASSWORD),
            token = tokenB,
        )
        assertThat(failedStatus).isEqualTo(401)
        assertThat(failedBody).contains("current password is incorrect")
        assertThat(failedBody).doesNotContain(WRONG_PASSWORD)
        assertThat(failedBody).doesNotContain(THIRD_PASSWORD)

        assertThat(persistedRevision()).isEqualTo(revisionBefore)
        val (stillValidStatus, _) = get("/api/v1/serverSettings", tokenB)
        assertThat(stillValidStatus).isEqualTo(200)

        val (retryLoginStatus, _) = login(SECOND_PASSWORD)
        assertThat(retryLoginStatus).isEqualTo(200)
    }

    @Test
    @Order(5)
    fun changePasswordWithoutValidSessionGetsGuidedUnauthorized() {
        val (noTokenStatus, noTokenBody) = post(
            "/api/v1/auth/change-password",
            body = mapOf("currentPassword" to SECOND_PASSWORD, "newPassword" to THIRD_PASSWORD),
            token = null,
        )
        assertThat(noTokenStatus).isEqualTo(401)
        assertThat(noTokenBody).contains("Sign in again")

        val (revokedTokenStatus, _) = post(
            "/api/v1/auth/change-password",
            body = mapOf("currentPassword" to SECOND_PASSWORD, "newPassword" to THIRD_PASSWORD),
            token = tokenA,
        )
        assertThat(revokedTokenStatus).isEqualTo(401)

        val (noTokenProtectedStatus, _) = get("/api/v1/serverSettings", token = null)
        assertThat(noTokenProtectedStatus).isEqualTo(401)
    }

    @Test
    @Order(6)
    fun tooShortNewPasswordIsRejectedWithoutRevoking() {
        val revisionBefore = persistedRevision()

        val (status, body) = post(
            "/api/v1/auth/change-password",
            body = mapOf("currentPassword" to SECOND_PASSWORD, "newPassword" to "short"),
            token = tokenB,
        )
        assertThat(status).isEqualTo(400)
        assertThat(body).contains("at least 8 characters")

        assertThat(persistedRevision()).isEqualTo(revisionBefore)
        val (stillValidStatus, _) = get("/api/v1/serverSettings", tokenB)
        assertThat(stillValidStatus).isEqualTo(200)
    }

    @Test
    @Order(7)
    fun revocationIsAuditedWithoutSecrets() {
        val logFile = DATA_DIR.resolve("logs").resolve("latest.log")
        assertThat(logFile).exists()
        val logContent = Files.readString(logFile)

        assertThat(logContent).contains("AUTH_SESSIONS_REVOKED")
        assertThat(logContent).contains("reason=PASSWORD_CHANGED")
        assertThat(logContent).contains("reason=PASSWORD_SET")

        assertThat(logContent).doesNotContain(INITIAL_PASSWORD)
        assertThat(logContent).doesNotContain(SECOND_PASSWORD)
        assertThat(logContent).doesNotContain(WRONG_PASSWORD)
        assertThat(logContent).doesNotContain(THIRD_PASSWORD)
        assertThat(logContent).doesNotContain(bootstrapToken)

        val persisted = jacksonObjectMapper().readValue<ServerSettings>(settingsFile.toFile())
        val persistedHash = persisted.adminPasswordHash
        assertThat(persistedHash).isNotBlank()
        assertThat(logContent).doesNotContain(requireNotNull(persistedHash))
    }

    private fun login(password: String): Pair<Int, String> =
        post("/api/v1/auth/login", body = mapOf("password" to password), token = null)

    private fun get(path: String, token: String?): Pair<Int, String> {
        val builder = HttpRequest.newBuilder(URI.create("$baseUrl$path")).GET()
        token?.let { builder.header("Authorization", "Bearer $it") }
        val response = client.send(builder.build(), HttpResponse.BodyHandlers.ofString())
        return response.statusCode() to response.body()
    }

    private fun post(path: String, body: Map<String, String>, token: String?): Pair<Int, String> {
        val builder = HttpRequest.newBuilder(URI.create("$baseUrl$path"))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(objectMapper.writeValueAsString(body)))
        token?.let { builder.header("Authorization", "Bearer $it") }
        val response = client.send(builder.build(), HttpResponse.BodyHandlers.ofString())
        return response.statusCode() to response.body()
    }

    private fun extractToken(body: String): String {
        val token = objectMapper.readTree(body)["token"]?.asText()
        assertThat(token).isNotBlank()
        return requireNotNull(token)
    }

    private fun persistedRevision(): Long? =
        jacksonObjectMapper().readValue<ServerSettings>(settingsFile.toFile()).passwordRevision

    companion object {
        private const val INITIAL_PASSWORD = "initial-e2e-password"
        private const val SECOND_PASSWORD = "rotated-e2e-password"
        private const val THIRD_PASSWORD = "third-e2e-password"
        private const val WRONG_PASSWORD = "wrong-e2e-password"

        // Assigned by the ordered narrative; shared across the sequence.
        private var tokenA: String = ""
        private var tokenB: String = ""
        private var bootstrapToken: String = ""

        private val STATE_DIR: Path = Files.createTempDirectory("moddex-auth-revocation-test")
        private val DATA_DIR: Path = STATE_DIR.resolve("data")
        private val settingsFile: Path
            get() = STATE_DIR.resolve("config").resolve("serversettings.json")
        private val proofFile: Path
            get() = STATE_DIR.resolve("config").resolve(SetupBootstrapProofService.PROOF_FILE_NAME)

        private fun currentBootstrapProof(): String {
            val token = jacksonObjectMapper().readTree(proofFile.toFile())["token"]?.asText()
            assertThat(token).isNotBlank()
            return requireNotNull(token)
        }

        @JvmStatic
        @DynamicPropertySource
        fun registerProperties(registry: DynamicPropertyRegistry) {
            registry.add("moddex.paths.config") { STATE_DIR.resolve("config").toString() }
            registry.add("moddex.paths.data") { DATA_DIR.toString() }
            registry.add("moddex.paths.logs") { DATA_DIR.resolve("logs").toString() }
        }
    }
}

package de.aklozyp.moddexbackend.api.server.service

import io.jsonwebtoken.Jwts
import jakarta.annotation.PostConstruct
import org.springframework.stereotype.Service
import java.util.Date
import javax.crypto.SecretKey

@Service
class JwtService(
    private val serverSettingsService: ServerSettingsService,
) {
    private val expirationMs = 86400000 // 24 hours
    private lateinit var secretKey: SecretKey

    @PostConstruct
    fun init() {
        // Generate a secure key for HS256
        secretKey = Jwts.SIG.HS256.key().build()
    }

    fun generateToken(username: String): String {
        val builder = Jwts.builder()
            .subject(username)
            .issuedAt(Date())
            .expiration(Date(System.currentTimeMillis() + expirationMs))
        // Pin the credential revision at issuance time; validateToken rejects tokens
        // pinned to an older revision after the administrator password changed.
        val passwordRevision = serverSettingsService.getPasswordRevision()
        if (passwordRevision != null) {
            builder.claim(PASSWORD_REVISION_CLAIM, passwordRevision)
        }
        return builder.signWith(secretKey).compact()
    }

    fun validateToken(token: String): Boolean {
        try {
            val claims = Jwts.parser()
                .verifyWith(secretKey)
                .build()
                .parseSignedClaims(token)
            // Revocation: tokens issued before the latest credential change are invalid.
            // Strictly read; an unreadable settings file fails closed.
            val currentRevision = serverSettingsService.getPasswordRevision() ?: return true
            val tokenRevision = (claims.payload[PASSWORD_REVISION_CLAIM] as? Number)?.toLong()
                ?: return false
            return tokenRevision >= currentRevision
        } catch (e: Exception) {
            return false
        }
    }

    fun getUsernameFromToken(token: String): String {
        return Jwts.parser()
            .verifyWith(secretKey)
            .build()
            .parseSignedClaims(token)
            .payload
            .subject
    }

    companion object {
        const val PASSWORD_REVISION_CLAIM = "passwordRevision"
    }
}

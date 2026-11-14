package de.aklozyp.moddexbackend.api.server.service

import com.sun.net.httpserver.HttpServer
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Local loopback fixture server for artifact downloads; no real internet
 * access. Each path is bound to a fixed response, so tests can serve genuine
 * and tampered artifacts next to each other.
 */
internal class ArtifactFixtureServer : AutoCloseable {

    private class Response(val status: Int, val body: ByteArray, val headers: Map<String, String> = emptyMap())

    private val responses = ConcurrentHashMap<String, Response>()
    private val requestCounts = ConcurrentHashMap<String, AtomicInteger>()
    private val server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)

    val baseUrl: String = "http://127.0.0.1:${server.address.port}"

    fun url(path: String): String = "$baseUrl$path"

    init {
        server.createContext("/") { exchange ->
            try {
                val path = exchange.requestURI.path
                requestCounts.computeIfAbsent(path) { AtomicInteger() }.incrementAndGet()
                val response = responses[path] ?: Response(404, ByteArray(0))
                response.headers.forEach { (name, value) -> exchange.responseHeaders.add(name, value) }
                val length = if (response.body.isEmpty()) -1 else response.body.size.toLong()
                exchange.sendResponseHeaders(response.status, length)
                if (response.body.isNotEmpty()) {
                    exchange.responseBody.use { it.write(response.body) }
                }
            } finally {
                exchange.close()
            }
        }
        server.start()
    }

    fun serve(path: String, body: ByteArray, status: Int = 200, headers: Map<String, String> = emptyMap()) {
        responses[path] = Response(status, body, headers)
    }

    fun serveSha1Sidecar(path: String, artifactBody: ByteArray) {
        responses["$path.sha1"] = Response(200, "${sha1Hex(artifactBody)}\n".toByteArray())
    }

    fun serveClaimedSha1Sidecar(path: String, claimedSha1: String) {
        responses["$path.sha1"] = Response(200, claimedSha1.toByteArray())
    }

    fun serveRedirect(path: String, location: String) {
        responses[path] = Response(302, ByteArray(0), headers = mapOf("Location" to location))
    }

    fun hits(path: String): Int = requestCounts[path]?.get() ?: 0

    override fun close() {
        server.stop(0)
    }

    companion object {
        fun sha1Hex(bytes: ByteArray): String = digest("SHA-1", bytes)
        fun sha256Hex(bytes: ByteArray): String = digest("SHA-256", bytes)

        private fun digest(algorithm: String, bytes: ByteArray): String =
            MessageDigest.getInstance(algorithm).digest(bytes).joinToString("") { "%02x".format(it) }
    }
}

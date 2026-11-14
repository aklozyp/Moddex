package de.aklozyp.moddexbackend.config

import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.http.client.reactive.ReactorClientHttpConnector
import org.springframework.web.reactive.function.client.ExchangeStrategies
import org.springframework.web.reactive.function.client.WebClient
import reactor.netty.http.client.HttpClient
import java.time.Duration

@Configuration
class HttpConfig {
    @Bean
    fun webClient(): WebClient {
        val http = HttpClient.create()
            .responseTimeout(Duration.ofSeconds(20))
        return WebClient.builder()
            .clientConnector(ReactorClientHttpConnector(http))
            .exchangeStrategies(
                ExchangeStrategies.builder()
                    .codecs { it.defaultCodecs().maxInMemorySize(16 * 1024 * 1024) }
                    .build()
            )
            .build()
    }
}
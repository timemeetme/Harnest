package com.harnest.app.dsh.transport

import io.ktor.client.*
import io.ktor.client.engine.okhttp.*
import io.ktor.client.plugins.websocket.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.serialization.kotlinx.json.*

actual fun defaultHttpClient(): HttpClient = HttpClient(OkHttp) {
    install(WebSockets)
    install(ContentNegotiation) { json(dshJson) }
}

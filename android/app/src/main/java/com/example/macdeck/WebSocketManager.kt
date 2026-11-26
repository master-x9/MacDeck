package com.example.macdeck

import android.util.Log
import okhttp3.*

class WebSocketManager(
    private val clientID: String,
    private val deviceName: String,
    private val gridRows: Int,
    private val onMessage: (ServerMessage) -> Unit,
    private val onStatusChange: (ConnectionStatus) -> Unit
) {
    companion object {
        // Shared across every WebSocketManager instance. AppState creates a new
        // WebSocketManager on every reconnect (each NSD resolve), and a fresh
        // OkHttpClient() per instance was never shut down — each one owns its
        // own dispatcher thread pool and connection pool, so over a session of
        // repeated reconnects those threads/sockets just accumulated and leaked.
        // One shared client reuses its pool across reconnects instead.
        private val sharedClient = OkHttpClient.Builder()
            .pingInterval(5, java.util.concurrent.TimeUnit.SECONDS)
            .build()
    }

    private val client = sharedClient
    private var webSocket: WebSocket? = null

    enum class ConnectionStatus {
        DISCONNECTED, CONNECTING, CONNECTED, FAILED
    }

    fun connect(host: String, port: Int) {
        val request = Request.Builder()
            .url("ws://$host:$port")
            .build()

        onStatusChange(ConnectionStatus.CONNECTING)
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d("WebSocketManager", "Connected to Mac")
                onStatusChange(ConnectionStatus.CONNECTED)
                sendHello()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                Log.d("WebSocketManager", "Received: $text")
                try {
                    val message = json.decodeFromString<ServerMessage>(text)
                    onMessage(message)
                } catch (e: Exception) {
                    Log.e("WebSocketManager", "Failed to decode message", e)
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.d("WebSocketManager", "Closing: $code / $reason")
                onStatusChange(ConnectionStatus.DISCONNECTED)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e("WebSocketManager", "Failure", t)
                onStatusChange(ConnectionStatus.FAILED)
            }
        })
    }

    private fun sendHello() {
        val hello = HelloCommand(clientID = clientID, deviceName = deviceName, gridRows = gridRows)
        val jsonText = clientJson.encodeToString(ClientCommand.serializer(), hello)
        webSocket?.send(jsonText)
    }

    fun triggerSlot(pageID: String, index: Int) {
        val trigger = TriggerSlotCommand(pageID = pageID, slotIndex = index)
        val jsonText = clientJson.encodeToString(ClientCommand.serializer(), trigger)
        webSocket?.send(jsonText)
    }


    fun requestSync() {
        val request = RequestSyncCommand()
        val jsonText = clientJson.encodeToString(ClientCommand.serializer(), request)
        webSocket?.send(jsonText)
    }

    fun disconnect() {
        webSocket?.close(1000, "User disconnected")
        webSocket = null
    }
}
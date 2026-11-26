package com.example.macdeck

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
sealed class TileType

@Serializable
@SerialName("app")
data class AppTile(val bundleIdentifier: String, val name: String) : TileType()

@Serializable
@SerialName("systemControl")
data class SystemControlTile(val action: String) : TileType()

@Serializable
@SerialName("browserControl")
data class BrowserControlTile(val action: String) : TileType()

@Serializable
@SerialName("website")
data class WebsiteTile(val url: String, val name: String) : TileType()

@Serializable
@SerialName("shortcut")
data class ShortcutTile(val name: String) : TileType()

/** Mirrors the Swift side's `TileType.defaultLabel` fallback. */
fun TileType.defaultLabel(): String = when (this) {
    is AppTile -> name
    is WebsiteTile -> name
    is ShortcutTile -> name
    is SystemControlTile -> action
    is BrowserControlTile -> action
}

@Serializable
data class DeckTile(
    val id: String,
    val slotIndex: Int,
    val tileType: TileType,
    val customLabel: String? = null,
    val iconData: String? = null // Base64 encoded bitmap
)

@Serializable
data class DeckPage(
    val id: String,
    val name: String,
    val pageNumber: Int,
    val tiles: List<DeckTile?> // 10 slots for 2x5 grid
)

@Serializable
sealed class ClientCommand

@Serializable
@SerialName("HELLO")
data class HelloCommand(
    val clientID: String,
    val deviceName: String,
    val protocolVersion: Int = 1,
    val gridRows: Int = 2
) : ClientCommand()

@Serializable
@SerialName("REQUEST_SYNC")
class RequestSyncCommand : ClientCommand()

@Serializable
@SerialName("PING")
class PingCommand : ClientCommand()

@Serializable
@SerialName("TRIGGER_SLOT")
data class TriggerSlotCommand(
    val pageID: String,
    val slotIndex: Int
) : ClientCommand()

@Serializable
sealed class ServerMessage

@Serializable
@SerialName("pairingPending")
class PairingPending : ServerMessage()

@Serializable
@SerialName("pairingApproved")
class PairingApproved : ServerMessage()

@Serializable
@SerialName("pairingDenied")
class PairingDenied : ServerMessage()

@Serializable
@SerialName("versionMismatch")
data class VersionMismatch(
    val requiredVersion: Int
) : ServerMessage()

@Serializable
@SerialName("pong")
class PongMessage : ServerMessage()

@Serializable
@SerialName("error")
data class ErrorMessage(val message: String) : ServerMessage()

@Serializable
@SerialName("pageSync")
data class PageSync(
    val page: List<DeckPage>
) : ServerMessage()

@Serializable
@SerialName("switchToPage")
data class SwitchToPage(
    val pageID: String
) : ServerMessage()

@Serializable
@SerialName("lockStateChanged")
data class LockStateChanged(
    val isLocked: Boolean
) : ServerMessage()

val json = Json {
    ignoreUnknownKeys = true
    classDiscriminator = "type"
}

val clientJson = Json {
    ignoreUnknownKeys = true
    classDiscriminator = "command"
}

/** A single MacDeck host discovered via Bonjour / NSD. */
data class DiscoveredMac(
    val name: String,     // Localized computer name from TXT record (or service name fallback)
    val hostId: String,   // Persistent UUID from TXT record (empty string if not present)
    val host: String,
    val port: Int
)
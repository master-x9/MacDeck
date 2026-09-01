package com.example.macdeck

import android.app.Application
import android.content.Context
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

sealed class AppUiState {
    object Searching : AppUiState()
    /** Multiple Macs found and no preferred one is on the network — let the user pick. */
    data class SelectingMac(val macs: List<DiscoveredMac>) : AppUiState()
    data class Connecting(val hostName: String) : AppUiState()
    data class PairingPending(val hostName: String) : AppUiState()
    data class PairingDenied(val hostName: String) : AppUiState()
    data class VersionMismatch(val requiredVersion: Int) : AppUiState()
    data class Paired(val pages: List<DeckPage>, val isDisconnected: Boolean = false, val isLocked: Boolean = false) : AppUiState()
}

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = application.getSharedPreferences("macdeck_prefs", Context.MODE_PRIVATE)

    private val _uiState = MutableStateFlow<AppUiState>(AppUiState.Searching)
    val uiState: StateFlow<AppUiState> = _uiState.asStateFlow()

    private val _scrollToPage = MutableSharedFlow<String>(replay = 0)
    val scrollToPage: SharedFlow<String> = _scrollToPage.asSharedFlow()

    private val clientID: String = prefs.getString("client_id", null) ?: run {
        val newID = UUID.randomUUID().toString()
        prefs.edit().putString("client_id", newID).apply()
        newID
    }

    var deviceName: String = prefs.getString("device_name", android.os.Build.MODEL) ?: android.os.Build.MODEL
        private set

    var gridRows: Int = prefs.getInt("grid_rows", 2)
        private set

    /** hostId of the Mac the user last intentionally connected to. */
    private var preferredHostId: String = prefs.getString("preferred_host_id", "") ?: ""

    private var discoveryManager: DiscoveryManager? = null
    private var webSocketManager: WebSocketManager? = null
    private var lastPairedPages: List<DeckPage> = emptyList()

    /** Live list of every MacDeck service currently visible on the network. */
    private val discoveredMacs = mutableListOf<DiscoveredMac>()

    /** serviceName (Bonjour instance name) → DiscoveredMac, so lost events can remove by name. */
    private val macByServiceName = mutableMapOf<String, DiscoveredMac>()

    /** The Mac we are currently connected / connecting to. */
    private var activeMac: DiscoveredMac? = null

    init {
        discoveryManager = DiscoveryManager(
            application,
            onServiceResolved = { mac -> onMacFound(mac) },
            onServiceLost = { serviceName -> onMacLost(serviceName) }
        )
        startDiscovery()
    }

    // ---------------------------------------------------------------------------
    // Discovery events
    // ---------------------------------------------------------------------------

    private fun onMacFound(mac: DiscoveredMac) {
        viewModelScope.launch {
            // Deduplicate by hostId (if present) or by host:port.
            val existing = discoveredMacs.indexOfFirst {
                (mac.hostId.isNotEmpty() && it.hostId == mac.hostId) ||
                (it.host == mac.host && it.port == mac.port)
            }
            if (existing >= 0) {
                discoveredMacs[existing] = mac   // refresh metadata
            } else {
                discoveredMacs.add(mac)
            }
            // Keep reverse index by name (service instance name used by NSD lost events).
            macByServiceName[mac.name] = mac

            Log.d(TAG, "Macs on network: ${discoveredMacs.map { it.name }}")
            evaluateDiscoveredMacs()
        }
    }

    private fun onMacLost(serviceName: String) {
        viewModelScope.launch {
            val removed = macByServiceName.remove(serviceName)
            if (removed != null) {
                discoveredMacs.removeAll { it.hostId == removed.hostId && it.name == removed.name }
                Log.d(TAG, "Mac left: ${removed.name} — remaining: ${discoveredMacs.map { it.name }}")
            }

            // If the active Mac disappeared, show disconnected and try to rediscover.
            if (removed != null && removed.hostId == activeMac?.hostId) {
                val currentState = _uiState.value
                if (currentState is AppUiState.Paired) {
                    _uiState.value = currentState.copy(isDisconnected = true)
                    viewModelScope.launch {
                        kotlinx.coroutines.delay(5000)
                        if (_uiState.value is AppUiState.Paired &&
                            (_uiState.value as AppUiState.Paired).isDisconnected) {
                            activeMac = null
                            startDiscovery()
                        }
                    }
                } else {
                    activeMac = null
                    evaluateDiscoveredMacs()
                }
            } else {
                // Update picker if it's currently visible.
                if (_uiState.value is AppUiState.SelectingMac) {
                    evaluateDiscoveredMacs()
                }
            }
        }
    }

    /**
     * Decide what to do given the current list of discovered Macs:
     *  - 0 Macs  → stay in Searching
     *  - 1 Mac   → connect automatically
     *  - N Macs, preferred one present → connect to it automatically
     *  - N Macs, no preferred match   → show SelectingMac picker
     */
    private fun evaluateDiscoveredMacs() {
        // Don't disrupt an active connection.
        val state = _uiState.value
        if (state is AppUiState.Connecting ||
            state is AppUiState.PairingPending ||
            (state is AppUiState.Paired && !state.isDisconnected)) return

        when {
            discoveredMacs.isEmpty() -> {
                _uiState.value = AppUiState.Searching
            }
            discoveredMacs.size == 1 -> {
                connectToMac(discoveredMacs.first())
            }
            else -> {
                // Multiple Macs: check for the preferred one.
                val preferred = discoveredMacs.find { it.hostId == preferredHostId }
                if (preferred != null) {
                    connectToMac(preferred)
                } else {
                    _uiState.value = AppUiState.SelectingMac(discoveredMacs.toList())
                }
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Connection management
    // ---------------------------------------------------------------------------

    private fun startDiscovery() {
        _uiState.value = AppUiState.Searching
        discoveryManager?.startDiscovery()
    }

    /** Called when the user taps a Mac in the picker, or internally for auto-connect. */
    fun connectToMac(mac: DiscoveredMac) {
        activeMac = mac
        _uiState.value = AppUiState.Connecting(mac.name)
        discoveryManager?.stopDiscovery()
        webSocketManager?.disconnect()
        webSocketManager = WebSocketManager(
            clientID = clientID,
            deviceName = deviceName,
            gridRows = gridRows,
            onMessage = { message -> handleServerMessage(message, mac.name) },
            onStatusChange = { status -> handleStatusChange(status, mac.name) }
        )
        webSocketManager?.connect(mac.host, mac.port)
    }

    private fun handleServerMessage(message: ServerMessage, hostName: String) {
        viewModelScope.launch {
            when (message) {
                is PairingPending -> _uiState.value = AppUiState.PairingPending(hostName)
                is PairingApproved -> {
                    // Save this Mac as preferred now that pairing succeeded.
                    activeMac?.hostId?.takeIf { it.isNotEmpty() }?.let { id ->
                        preferredHostId = id
                        prefs.edit().putString("preferred_host_id", id).apply()
                    }
                    val isLocked = (_uiState.value as? AppUiState.Paired)?.isLocked ?: false
                    _uiState.value = AppUiState.Paired(lastPairedPages, isLocked = isLocked)
                    webSocketManager?.requestSync()
                }
                is PairingDenied -> {
                    _uiState.value = AppUiState.PairingDenied(hostName)
                    webSocketManager?.disconnect()
                    viewModelScope.launch {
                        kotlinx.coroutines.delay(3000)
                        activeMac = null
                        startDiscovery()
                    }
                }
                is VersionMismatch -> {
                    _uiState.value = AppUiState.VersionMismatch(message.requiredVersion)
                    webSocketManager?.disconnect()
                }
                is PageSync -> {
                    lastPairedPages = message.page
                    val isLocked = (_uiState.value as? AppUiState.Paired)?.isLocked ?: false
                    _uiState.value = AppUiState.Paired(message.page, isLocked = isLocked)
                }
                is SwitchToPage -> {
                    _scrollToPage.emit(message.pageID)
                }
                is LockStateChanged -> {
                    val current = _uiState.value
                    if (current is AppUiState.Paired) {
                        Log.d(TAG, "Lock state: ${current.isLocked} → ${message.isLocked}")
                        _uiState.value = current.copy(isLocked = message.isLocked)
                    }
                }
                is ErrorMessage -> Log.e(TAG, "Server Error: ${message.message}")
                is PongMessage  -> Log.d(TAG, "Pong received")
                else -> {}
            }
        }
    }

    private fun handleStatusChange(status: WebSocketManager.ConnectionStatus, hostName: String) {
        viewModelScope.launch {
            when (status) {
                WebSocketManager.ConnectionStatus.DISCONNECTED,
                WebSocketManager.ConnectionStatus.FAILED -> {
                    val currentState = _uiState.value
                    if (currentState is AppUiState.Paired) {
                        _uiState.value = currentState.copy(isDisconnected = true)
                        viewModelScope.launch {
                            kotlinx.coroutines.delay(5000)
                            if (_uiState.value is AppUiState.Paired &&
                                (_uiState.value as AppUiState.Paired).isDisconnected) {
                                activeMac = null
                                startDiscovery()
                            }
                        }
                    } else if (currentState !is AppUiState.PairingDenied &&
                               currentState !is AppUiState.VersionMismatch) {
                        activeMac = null
                        startDiscovery()
                    }
                }
                else -> {}
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Public actions
    // ---------------------------------------------------------------------------

    fun triggerSlot(pageID: String, index: Int) {
        webSocketManager?.triggerSlot(pageID, index)
    }

    fun requestSync() {
        Log.d(TAG, "Manually requesting sync")
        webSocketManager?.requestSync()
    }

    fun updateDeviceName(name: String) {
        deviceName = name
        prefs.edit().putString("device_name", name).apply()
        webSocketManager?.disconnect()
        activeMac = null
        startDiscovery()
    }

    fun updateGridRows(rows: Int) {
        gridRows = rows
        prefs.edit().putInt("grid_rows", rows).apply()
        webSocketManager?.disconnect()
        activeMac = null
        startDiscovery()
    }

    fun resetPairing() {
        val newID = UUID.randomUUID().toString()
        prefs.edit().putString("client_id", newID).apply()
        preferredHostId = ""
        prefs.edit().remove("preferred_host_id").apply()
        webSocketManager?.disconnect()
        activeMac = null
        startDiscovery()
    }

    override fun onCleared() {
        super.onCleared()
        discoveryManager?.stopDiscovery()
        webSocketManager?.disconnect()
    }

    companion object {
        private const val TAG = "AppViewModel"
    }
}
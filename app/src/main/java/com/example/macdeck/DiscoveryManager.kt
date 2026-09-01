package com.example.macdeck

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/**
 * Discovers all MacDeck services on the local network simultaneously.
 *
 * - Every resolved service calls [onServiceResolved] with full metadata parsed from the
 *   Bonjour TXT record (name, hostId, host, port).
 * - Lost services call [onServiceLost] with the service's instance name so callers can
 *   remove the right entry from their list.
 * - Multiple Macs on the same subnet are all discovered in parallel — there is no
 *   "first one wins" guard any more.
 */
class DiscoveryManager(
    context: Context,
    private val onServiceResolved: (mac: DiscoveredMac) -> Unit,
    private val onServiceLost: (serviceName: String) -> Unit
) {
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val serviceType = "_macdeck._tcp."

    private var isSearching = false
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    // Track service names currently being resolved so we don't spin up duplicate resolve ops.
    private val resolvingNames = mutableSetOf<String>()

    fun startDiscovery() {
        if (isSearching) return
        isSearching = true

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                Log.d(TAG, "Service discovery started")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName
                Log.d(TAG, "Service found: $name (type=${serviceInfo.serviceType})")

                synchronized(resolvingNames) {
                    if (resolvingNames.contains(name)) {
                        Log.d(TAG, "Already resolving $name — skipping duplicate")
                        return
                    }
                    resolvingNames.add(name)
                }

                // Create a fresh ResolveListener per service so concurrent resolves don't
                // share state and shadow each other.
                nsdManager.resolveService(serviceInfo, makeResolveListener(name))
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName
                Log.d(TAG, "Service lost: $name")
                synchronized(resolvingNames) { resolvingNames.remove(name) }
                onServiceLost(name)
            }

            override fun onDiscoveryStopped(regType: String) {
                Log.i(TAG, "Discovery stopped: $regType")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Discovery failed to start: $errorCode")
                try { nsdManager.stopServiceDiscovery(this) } catch (e: Exception) { }
                isSearching = false
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Stop discovery failed: $errorCode")
                try { nsdManager.stopServiceDiscovery(this) } catch (e: Exception) { }
            }
        }

        discoveryListener = listener
        nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stopDiscovery() {
        if (!isSearching) return
        isSearching = false
        synchronized(resolvingNames) { resolvingNames.clear() }
        discoveryListener?.let {
            try {
                nsdManager.stopServiceDiscovery(it)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping discovery", e)
            }
        }
        discoveryListener = null
    }

    // ---------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------

    private fun makeResolveListener(serviceName: String) = object : NsdManager.ResolveListener {
        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            Log.e(TAG, "Resolve failed for $serviceName: $errorCode")
            synchronized(resolvingNames) { resolvingNames.remove(serviceName) }
        }

        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
            synchronized(resolvingNames) { resolvingNames.remove(serviceName) }

            val host = serviceInfo.host?.hostAddress ?: ""
            val port = serviceInfo.port

            // Parse TXT record for name and hostId.
            val txtName = parseTxtValue(serviceInfo, "name") ?: serviceName
            val hostId  = parseTxtValue(serviceInfo, "hostId") ?: ""

            Log.d(TAG, "Resolved: $txtName ($hostId) at $host:$port")
            onServiceResolved(DiscoveredMac(name = txtName, hostId = hostId, host = host, port = port))
        }
    }

    /**
     * Extract a single string value from an NSD TXT record by key.
     * NSD delivers TXT attributes as a Map<String, ByteArray> on API 21+.
     */
    @Suppress("UNCHECKED_CAST")
    private fun parseTxtValue(serviceInfo: NsdServiceInfo, key: String): String? {
        return try {
            val attrs = serviceInfo.attributes as? Map<String, ByteArray> ?: return null
            attrs[key]?.toString(Charsets.UTF_8)?.takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse TXT record key '$key'", e)
            null
        }
    }

    companion object {
        private const val TAG = "DiscoveryManager"
    }
}

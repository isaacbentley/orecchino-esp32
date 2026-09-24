// WifiRidPlugin.kt — the phone's own Wi-Fi Remote ID receiver (Android).
// Hands raw payloads to Dart (lib/core/native_rx/wifi_rid_android.dart),
// which does every bit of parsing and decoding (lib/core/odid):
//
//   * NAN: a passive Wi-Fi Aware subscribe to "org.opendroneid.remoteid",
//     the service ASTM F3411 transmitters publish (unsolicited) and the
//     firmware's TX test beacon sends (firmware/common/tx_core.h build_nan:
//     service ID SHA-256(name)[0..5] = 88 69 19 9D 92 09, service info =
//     [counter][message pack]). Each onServiceDiscovered delivers that
//     service info. Android shows neither the peer's MAC nor an RSSI.
//   * Beacon: Wi-Fi scan results' information elements (Android 11+,
//     ScanResult.getInformationElements), vendor element 221 with OUI
//     FA:0B:BC or 90:3A:E6 and type 0x0D, delivered as the element body.
//     A foreground app may start four scans every two minutes, so a scan is
//     asked for every [beaconIntervalMs] (30 s) and results from anyone's
//     scans are read when the system announces them. Slow by design.
//
// MethodChannel "orecchino/wifi_rid": capabilities, requestPermissions,
// start {nan, beacon, beaconIntervalMs}, stop.
// EventChannel "orecchino/wifi_rid/events": maps of kind nan / beacon /
// status (see the Dart file for the fields).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
package dev.bentley.orecchino_mobile

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareSession
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

@SuppressLint("MissingPermission", "NewApi")
class WifiRidPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val SERVICE_NAME = "org.opendroneid.remoteid"
        private const val PERMISSION_REQUEST = 0x0D1D
        private const val DEFAULT_BEACON_INTERVAL_MS = 30_000L
        private const val MIN_BEACON_INTERVAL_MS = 5_000L
    }

    private lateinit var context: Context
    private var method: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var activity: ActivityPluginBinding? = null
    private var pendingPermissions: MethodChannel.Result? = null

    // NAN
    private var awareWanted = false
    private var awareSession: WifiAwareSession? = null
    private var subscribeSession: SubscribeDiscoverySession? = null
    private var awareReceiver: BroadcastReceiver? = null

    // Beacons
    private var beaconWanted = false
    private var beaconIntervalMs = DEFAULT_BEACON_INTERVAL_MS
    private var scanReceiver: BroadcastReceiver? = null
    private val lastSeenUs = HashMap<String, Long>()   // BSSID -> newest scan result delivered
    private val scanTick = object : Runnable {
        override fun run() {
            if (!beaconWanted) return
            requestScan()
            main.postDelayed(this, beaconIntervalMs)
        }
    }

    private val wifi: WifiManager?
        get() = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager?

    private val aware: WifiAwareManager?
        get() = if (Build.VERSION.SDK_INT >= 26)
            context.getSystemService(Context.WIFI_AWARE_SERVICE) as WifiAwareManager? else null

    // ------------------------------------------------------------ plugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        method = MethodChannel(binding.binaryMessenger, "orecchino/wifi_rid").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "orecchino/wifi_rid/events").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopAll()
        method?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        method = null
        events = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "requestPermissions" -> requestPermissions(result)
            "start" -> {
                val nan = call.argument<Boolean>("nan") ?: true
                val beacon = call.argument<Boolean>("beacon") ?: true
                val every = (call.argument<Number>("beaconIntervalMs")?.toLong() ?: DEFAULT_BEACON_INTERVAL_MS)
                    .coerceAtLeast(MIN_BEACON_INTERVAL_MS)
                val out = HashMap<String, String>()
                if (nan) out["nan"] = startAware()
                if (beacon) out["beacon"] = startBeacons(every)
                result.success(out)
            }
            "stop" -> {
                stopAll()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------ capabilities

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** NEARBY_WIFI_DEVICES on 13+, fine location before (Wi-Fi Aware's rule). */
    private fun awarePermission() =
        if (Build.VERSION.SDK_INT >= 33) granted(Manifest.permission.NEARBY_WIFI_DEVICES)
        else granted(Manifest.permission.ACCESS_FINE_LOCATION)

    /** Scan results are location data on every version. */
    private fun beaconPermission() = granted(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun locationEnabled(): Boolean? {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager? ?: return null
        return if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else null
    }

    private fun capabilities(): Map<String, Any?> {
        val m = HashMap<String, Any?>()
        m["platform"] = "android"
        m["sdk"] = Build.VERSION.SDK_INT
        val awareFeature = Build.VERSION.SDK_INT >= 26 &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
        m["awareFeature"] = awareFeature
        m["awareAvailable"] = awareFeature && (aware?.isAvailable ?: false)
        m["beaconIe"] = Build.VERSION.SDK_INT >= 30
        m["beaconIntervalMs"] = beaconIntervalMs.toInt()
        m["nearbyWifiPermission"] = if (Build.VERSION.SDK_INT >= 33) granted(Manifest.permission.NEARBY_WIFI_DEVICES) else null
        m["fineLocationPermission"] = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        m["locationEnabled"] = locationEnabled()
        m["wifiEnabled"] = try { wifi?.isWifiEnabled } catch (e: Exception) { null }
        try {
            val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?)?.adapter
            if (adapter != null && Build.VERSION.SDK_INT >= 26) {
                m["leCodedPhy"] = adapter.isLeCodedPhySupported
                m["leExtendedAdvertising"] = adapter.isLeExtendedAdvertisingSupported
                m["leMaxAdvDataLength"] = adapter.leMaximumAdvertisingDataLength
            }
        } catch (e: Exception) {
            // leave them unknown
        }
        return m
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        val act = activity?.activity
        val wanted = ArrayList<String>()
        if (Build.VERSION.SDK_INT >= 33) wanted.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        wanted.add(Manifest.permission.ACCESS_FINE_LOCATION)
        wanted.add(Manifest.permission.ACCESS_COARSE_LOCATION)
        val missing = wanted.filter { !granted(it) }
        if (missing.isEmpty() || act == null || pendingPermissions != null) {
            result.success(wanted.associateWith { granted(it) })
            return
        }
        pendingPermissions = result
        act.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val r = pendingPermissions ?: return true
        pendingPermissions = null
        val out = HashMap<String, Boolean>()
        if (Build.VERSION.SDK_INT >= 33) out[Manifest.permission.NEARBY_WIFI_DEVICES] = granted(Manifest.permission.NEARBY_WIFI_DEVICES)
        out[Manifest.permission.ACCESS_FINE_LOCATION] = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        out[Manifest.permission.ACCESS_COARSE_LOCATION] = granted(Manifest.permission.ACCESS_COARSE_LOCATION)
        r.success(out)
        return true
    }

    // --------------------------------------------------------------- NAN

    private fun status(path: String, state: String, message: String? = null) {
        sink?.success(mapOf("kind" to "status", "path" to path, "state" to state, "message" to message))
    }

    private fun startAware(): String {
        if (Build.VERSION.SDK_INT < 26) return "unsupported: needs Android 8"
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) return "unsupported: no Wi-Fi Aware"
        if (!awarePermission()) return "permission"
        val mgr = aware ?: return "unsupported: no Wi-Fi Aware service"
        awareWanted = true
        if (awareReceiver == null) {
            awareReceiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    if (mgr.isAvailable) {
                        if (awareWanted && awareSession == null) attachAware(mgr)
                    } else {
                        closeAware()
                        status("nan", "unavailable", "Wi-Fi Aware is off (Wi-Fi off, hotspot or another connection)")
                    }
                }
            }
            val filter = IntentFilter(WifiAwareManager.ACTION_WIFI_AWARE_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(awareReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else context.registerReceiver(awareReceiver, filter)
        }
        if (!mgr.isAvailable) return "waiting"
        if (awareSession == null) attachAware(mgr)
        return "started"
    }

    private fun attachAware(mgr: WifiAwareManager) {
        mgr.attach(object : AttachCallback() {
            override fun onAttached(session: WifiAwareSession) {
                if (!awareWanted) {
                    session.close()
                    return
                }
                awareSession = session
                val cfg = SubscribeConfig.Builder()
                    .setServiceName(SERVICE_NAME)
                    .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_PASSIVE)
                    .build()
                session.subscribe(cfg, object : DiscoverySessionCallback() {
                    override fun onSubscribeStarted(s: SubscribeDiscoverySession) {
                        subscribeSession = s
                        status("nan", "subscribed")
                    }

                    override fun onServiceDiscovered(peer: PeerHandle, info: ByteArray?, matchFilter: MutableList<ByteArray>?) {
                        if (info == null || info.size < 26) return
                        sink?.success(mapOf(
                            "kind" to "nan",
                            "data" to info,
                            "peer" to peer.hashCode(),
                            "ts" to System.currentTimeMillis(),
                        ))
                    }

                    override fun onSessionConfigFailed() = status("nan", "error", "subscribe failed")

                    override fun onSessionTerminated() {
                        subscribeSession = null
                        status("nan", "terminated")
                    }
                }, main)
            }

            override fun onAttachFailed() = status("nan", "error", "attach failed")
        }, main)
    }

    private fun closeAware() {
        subscribeSession?.close()
        subscribeSession = null
        awareSession?.close()
        awareSession = null
    }

    private fun stopAware() {
        awareWanted = false
        closeAware()
        awareReceiver?.let { try { context.unregisterReceiver(it) } catch (e: Exception) {} }
        awareReceiver = null
    }

    // ----------------------------------------------------------- beacons

    private fun startBeacons(every: Long): String {
        if (Build.VERSION.SDK_INT < 30) return "unsupported: needs Android 11"
        if (!beaconPermission()) return "permission"
        if (wifi == null) return "unsupported: no Wi-Fi"
        beaconIntervalMs = every
        beaconWanted = true
        if (scanReceiver == null) {
            scanReceiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) = deliverScanResults()
            }
            val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
            if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(scanReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else context.registerReceiver(scanReceiver, filter)
        }
        main.removeCallbacks(scanTick)
        main.post(scanTick)
        deliverScanResults()   // whatever the last scan (anyone's) found
        return "started"
    }

    @Suppress("DEPRECATION")
    private fun requestScan() {
        try {
            // False when throttled (4 per 2 min in the foreground); results
            // from other scans still arrive through the broadcast.
            if (wifi?.startScan() != true) status("beacon", "throttled")
        } catch (e: SecurityException) {
            status("beacon", "permission", e.message)
        }
    }

    @Suppress("DEPRECATION")
    private fun deliverScanResults() {
        if (!beaconWanted || Build.VERSION.SDK_INT < 30) return
        val results: List<ScanResult> = try {
            wifi?.scanResults ?: return
        } catch (e: SecurityException) {
            status("beacon", "permission", e.message)
            return
        }
        // ScanResult.timestamp is microseconds since boot.
        val bootWallMs = System.currentTimeMillis() - SystemClock.elapsedRealtime()
        if (lastSeenUs.size > 512) lastSeenUs.clear()
        for (r in results) {
            val bssid = r.BSSID ?: continue
            val prev = lastSeenUs[bssid]
            if (prev != null && prev >= r.timestamp) continue   // already delivered
            lastSeenUs[bssid] = r.timestamp
            for (ie in r.informationElements) {
                if (ie.id != 221) continue
                val buf = ie.bytes.duplicate()
                if (buf.remaining() < 30) continue
                val body = ByteArray(buf.remaining())
                buf.get(body)
                if (body[3] != 0x0D.toByte()) continue
                val oui = ((body[0].toInt() and 0xFF) shl 16) or ((body[1].toInt() and 0xFF) shl 8) or (body[2].toInt() and 0xFF)
                if (oui != 0xFA0BBC && oui != 0x903AE6) continue
                sink?.success(mapOf(
                    "kind" to "beacon",
                    "ie" to body,
                    "bssid" to bssid,
                    "ssid" to (r.SSID ?: ""),
                    "rssi" to r.level,
                    "freq" to r.frequency,
                    "ts" to bootWallMs + r.timestamp / 1000,
                ))
            }
        }
    }

    private fun stopBeacons() {
        beaconWanted = false
        main.removeCallbacks(scanTick)
        scanReceiver?.let { try { context.unregisterReceiver(it) } catch (e: Exception) {} }
        scanReceiver = null
        lastSeenUs.clear()
    }

    private fun stopAll() {
        stopAware()
        stopBeacons()
    }
}

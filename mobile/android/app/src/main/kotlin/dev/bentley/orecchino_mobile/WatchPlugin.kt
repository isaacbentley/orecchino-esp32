// WatchPlugin.kt — the channel between the Dart side
// (lib/core/background/watch_service.dart) and OrecchinoWatchService, plus
// the CompanionDeviceManager association of a pinned detector.
//
// MethodChannel "orecchino/watch":
//   start {text, location} -> bool, update {text}, stop, running -> bool,
//   companionSupported -> bool, associations -> [MAC], associate {mac, name}
//   -> bool (the system's "Allow Orecchino to access T5?" dialog; needs the
//   Activity).
//   Native -> Dart: action {action: pause | stop | appeared, mac?}.
//
// An associated detector lets the app run and start its service from the
// background for it, and on Android 12+ Android wakes the app when the
// detector comes into range (DetectorPresenceService). Reconnecting is then
// a pending connect (autoConnect) rather than a scan loop.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
package dev.bentley.orecchino_mobile

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

@SuppressLint("MissingPermission", "NewApi")
class WatchPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val REQUEST_ASSOCIATE = 0x0C0D
        private val main = Handler(Looper.getMainLooper())

        @Volatile
        private var channel: MethodChannel? = null

        /** Tell the Dart side (from the service or the companion service). */
        fun send(action: String, mac: String? = null) {
            main.post { channel?.invokeMethod("action", hashMapOf("action" to action, "mac" to mac)) }
        }
    }

    private lateinit var context: Context
    private var activity: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var pendingMac: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "orecchino/watch").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeActivityResultListener(this)
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> result.success(
                OrecchinoWatchService.start(
                    context,
                    call.argument<String>("text") ?: "Orecchino watching",
                    call.argument<Boolean>("location") ?: false,
                ),
            )
            "update" -> {
                OrecchinoWatchService.update(context, call.argument<String>("text") ?: "Orecchino watching")
                result.success(null)
            }
            "stop" -> {
                OrecchinoWatchService.stop(context)
                result.success(null)
            }
            "running" -> result.success(OrecchinoWatchService.running)
            "companionSupported" -> result.success(cdm() != null)
            "associations" -> result.success(associations())
            "associate" -> associate(call.argument<String>("mac") ?: "", result)
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ companion

    private fun cdm(): CompanionDeviceManager? {
        if (Build.VERSION.SDK_INT < 26) return null
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)) return null
        return context.getSystemService(CompanionDeviceManager::class.java)
    }

    private fun associations(): List<String> {
        val m = cdm() ?: return emptyList()
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                m.myAssociations.mapNotNull { it.deviceMacAddress?.toString()?.uppercase() }
            } else {
                @Suppress("DEPRECATION")
                m.associations.map { it.uppercase() }
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun associate(mac: String, result: MethodChannel.Result) {
        val m = cdm()
        val act = activity?.activity
        val address = mac.uppercase()
        if (m == null || act == null || address.isEmpty() || pending != null) {
            result.success(false)
            return
        }
        if (associations().contains(address)) {
            observe(address)
            result.success(true)
            return
        }
        val filter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(ScanFilter.Builder().setDeviceAddress(address).build())
            .build()
        val request = AssociationRequest.Builder().addDeviceFilter(filter).setSingleDevice(true).build()
        pending = result
        pendingMac = address
        val callback = object : CompanionDeviceManager.Callback() {
            @Deprecated("Called by onAssociationPending on Android 13+")
            override fun onDeviceFound(chooserLauncher: IntentSender) = launch(act, chooserLauncher)

            override fun onAssociationPending(intentSender: IntentSender) = launch(act, intentSender)

            override fun onAssociationCreated(associationInfo: AssociationInfo) = finish(true)

            override fun onFailure(error: CharSequence?) = finish(false)
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                m.associate(request, context.mainExecutor, callback)
            } else {
                @Suppress("DEPRECATION")
                m.associate(request, callback, main)
            }
        } catch (e: Exception) {
            finish(false)
        }
    }

    private fun launch(act: Activity, sender: IntentSender) {
        try {
            act.startIntentSenderForResult(sender, REQUEST_ASSOCIATE, null, 0, 0, 0)
        } catch (e: Exception) {
            finish(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_ASSOCIATE) return false
        finish(resultCode == Activity.RESULT_OK)
        return true
    }

    private fun finish(ok: Boolean) {
        val r = pending ?: return
        pending = null
        val mac = pendingMac
        pendingMac = null
        if (ok && mac != null) observe(mac)
        main.post { r.success(ok) }
    }

    /** Android 12+: wake the app (DetectorPresenceService) when it is near. */
    private fun observe(mac: String) {
        if (Build.VERSION.SDK_INT < 31) return
        try {
            @Suppress("DEPRECATION")
            cdm()?.startObservingDevicePresence(mac)
        } catch (e: Exception) {
            // Not associated after all, or not allowed: the pending connect still works.
        }
    }
}

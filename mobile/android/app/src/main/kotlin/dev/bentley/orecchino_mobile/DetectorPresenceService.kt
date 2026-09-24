// DetectorPresenceService.kt — Android 12+ wakes the app through this
// companion service when an associated detector comes into range (see
// WatchPlugin.observe). It makes sure the app's engine is running
// (OrecchinoApplication) and tells the Dart side, which arms its pending
// connect to the detector (lib/app/app_controller.dart).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
package dev.bentley.orecchino_mobile

import android.companion.CompanionDeviceService
import android.os.Handler
import android.os.Looper
import android.annotation.TargetApi

@TargetApi(31)
class DetectorPresenceService : CompanionDeviceService() {
    @Deprecated("Android 13+ calls it from onDeviceAppeared(AssociationInfo)")
    override fun onDeviceAppeared(address: String) {
        Handler(Looper.getMainLooper()).post {
            OrecchinoApplication.engine(this)
            WatchPlugin.send("appeared", address.uppercase())
        }
    }

    @Deprecated("Android 13+ calls it from onDeviceDisappeared(AssociationInfo)")
    override fun onDeviceDisappeared(address: String) {
        // The pending connect simply waits.
    }
}

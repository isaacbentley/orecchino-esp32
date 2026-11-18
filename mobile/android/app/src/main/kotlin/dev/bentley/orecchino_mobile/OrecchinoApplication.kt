// OrecchinoApplication.kt — the app's one Flutter engine, made once per
// process and cached. MainActivity attaches to it and leaves it running when
// it goes away, so the Dart side (the detector link, the phone's receiver,
// the rules and the alerts: lib/app/app_controller.dart) keeps working while
// OrecchinoWatchService holds the process in the foreground. The companion
// service (DetectorPresenceService) makes the engine when Android wakes the
// app for the detector. Plugins that need an Activity get one only while it
// is on screen.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
package dev.bentley.orecchino_mobile

import android.app.Application
import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

class OrecchinoApplication : Application() {
    companion object {
        const val ENGINE_ID = "orecchino"

        /** The cached engine, made (and main() run) on first use. Main thread only. */
        fun engine(context: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
            val app = context.applicationContext
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            // Registers the generated plugins (flutter_blue_plus, geolocator, ...).
            val engine = FlutterEngine(app)
            // The app's own: the phone's Wi-Fi Remote ID receiver, and the
            // background service and companion association.
            engine.plugins.add(WifiRidPlugin())
            engine.plugins.add(WatchPlugin())
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            return engine
        }
    }
}

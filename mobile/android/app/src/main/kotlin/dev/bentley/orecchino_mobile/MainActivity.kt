// MainActivity.kt — the screen. It shows the app's one cached engine
// (OrecchinoApplication) and does not destroy it when it goes, so "Watch in
// the background" (OrecchinoWatchService) carries on without it.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
package dev.bentley.orecchino_mobile

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = OrecchinoApplication.engine(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false
}

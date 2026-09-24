import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // flutter_local_notifications: present alerts while the app is open.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    // Core Bluetooth state restoration: when iOS relaunches the app in the
    // background for the detector (a pending connect completed, or the link
    // had data), launchOptions carries .bluetoothCentrals. The engine starts
    // as usual and main() opts flutter_blue_plus into restoration before any
    // other Bluetooth call, so its central manager comes back with the same
    // restore identifier and picks the detector up in willRestoreState.
    if launchOptions?[.bluetoothCentrals] != nil {
      NSLog("Orecchino: relaunched for Bluetooth state restoration")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

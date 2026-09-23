// commands.dart — Command builders for Orecchino host link
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

class HostCommands {
  static String setTime(int utcSeconds) {
    return jsonEncode({
      'cmd': 'set_time',
      'utc': utcSeconds,
    });
  }

  static String setHome({
    required double lat,
    required double lon,
    double? accuracyM,
    String source = 'phone',
  }) {
    final map = <String, dynamic>{
      'cmd': 'set_home',
      'lat': double.parse(lat.toStringAsFixed(6)),
      'lon': double.parse(lon.toStringAsFixed(6)),
      'src': source,
    };
    if (accuracyM != null && accuracyM.isFinite) {
      map['acc'] = double.parse(accuracyM.toStringAsFixed(1));
    }
    return jsonEncode(map);
  }

  static String feed({required bool on}) {
    return jsonEncode({
      'cmd': 'feed',
      'on': on,
    });
  }

  static String logGet({int since = 0, int? afterUtc}) {
    final map = <String, dynamic>{
      'cmd': 'log_get',
      'since': since,
    };
    if (afterUtc != null) {
      map['after_utc'] = afterUtc;
    }
    return jsonEncode(map);
  }

  static String wifiScan() => jsonEncode({'cmd': 'wifi_scan'});

  /// [psk] "" joins an open network; null joins with the saved password.
  static String wifiJoin({required String ssid, String? psk}) {
    return jsonEncode({
      'cmd': 'wifi_join',
      'ssid': ssid,
      if (psk != null) 'psk': psk,
    });
  }

  static String wifiForget({required String ssid}) {
    return jsonEncode({
      'cmd': 'wifi_forget',
      'ssid': ssid,
    });
  }

  static String wifiMode({required String mode, int everyMin = 15}) {
    return jsonEncode({
      'cmd': 'wifi_mode',
      'mode': mode,
      'every_min': everyMin,
    });
  }

  static String wifiStatus() => jsonEncode({'cmd': 'wifi_status'});
}

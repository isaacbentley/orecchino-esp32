// uas_models_test.dart — the phone's make/model table is the same as
// tools/uas_models.json (the source of truth for the firmware and the Mac).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/uas_models.dart';

void main() {
  test('the table matches tools/uas_models.json', () {
    final j = jsonDecode(File('../tools/uas_models.json').readAsStringSync()) as Map<String, dynamic>;
    expect(UasModels.manufacturers, Map<String, String>.from(j['manufacturers'] as Map));
    expect(UasModels.models, Map<String, String>.from(j['models'] as Map));
    expect(UasModels.manufacturer('1581F6Z9ABCDEF'), 'DJI');
    expect(UasModels.model('1581f6z9abcdef'), 'DJI Mini 4 Pro');
    expect(UasModels.model('1581'), isNull);
  });
}

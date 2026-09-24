// shader_test.dart — the living background's fragment shader compiles (at
// build time, by impellerc, from shaders/aurora.frag with its required
// `#version 460 core` header) and loads with the uniforms the painter sets.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('aurora.frag loads and takes its 14 uniforms', () async {
    final program = await ui.FragmentProgram.fromAsset('shaders/aurora.frag');
    final shader = program.fragmentShader();
    // uSize (2), uTime, uDeep/uMid/uHigh (3 each), uPulse, uPx: 14 floats,
    // in the order LivingBackground sets them.
    for (var i = 0; i < 14; i++) {
      shader.setFloat(i, 0.5);
    }
    expect(() => shader.setFloat(14, 0), throwsA(anything));
    shader.dispose();
  });
}

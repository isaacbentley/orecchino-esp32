// aurora.frag — the living background: slow aurora curtains and a nebula
// glow over deep space, in three colours given by the app (the threat
// palette in lib/ui/theme/colors.dart). The output only mixes between those
// three colours (plus faint star points), so it is never brighter than the
// palette's highlight; text contrast is checked against that.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform vec3 uDeep;
uniform vec3 uMid;
uniform vec3 uHigh;
uniform float uPulse;
uniform float uPx; // rendered pixels per screen point (the aurora is drawn small)

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;
  float aspect = uSize.x / max(uSize.y, 1.0);
  vec2 p = vec2(uv.x * aspect, uv.y);
  float t = uTime * 0.035;

  // Nebula: a broad, slowly drifting glow.
  float glow = smoothstep(0.25, 0.85, fbm(p * 1.3 + vec2(-t, t * 0.6)));

  // Curtains: bands warped by a second field, strongest high in the sky.
  float warp = fbm(vec2(p.x * 1.4 + t, p.y * 0.5 - t * 0.4));
  float band = fbm(vec2(p.x * 2.4 + warp * 2.2 - t * 1.2, p.y * 0.7 + t * 0.3));
  float curtain = smoothstep(0.42, 0.86, band) * smoothstep(0.95, 0.05, uv.y);
  float shimmer = 0.8 + 0.2 * sin(uTime * 0.6 + p.x * 6.0 + warp * 4.0);

  vec3 col = uDeep;
  col = mix(col, uMid, glow * 0.8);
  col = mix(col, uHigh, clamp(curtain * shimmer * (0.8 + 0.2 * uPulse), 0.0, 1.0));

  // Vignette toward deep space at the edges.
  float vig = smoothstep(1.3, 0.3, length((uv - vec2(0.5, 0.42)) * vec2(aspect * 0.9, 1.0)));
  col = mix(uDeep, col, vig);

  // A few faint round stars where the curtains are thin: one candidate per
  // 9 px cell, a soft point at a random spot inside it.
  vec2 pt = frag / max(uPx, 0.01); // in screen points, whatever the render scale
  vec2 cell = floor(pt / 9.0);
  float s = hash(cell);
  vec2 spot = (cell + 0.2 + 0.6 * vec2(hash(cell + 7.1), hash(cell + 3.3))) * 9.0;
  float d = length(pt - spot);
  float twinkle = 0.55 + 0.45 * sin(uTime * (0.6 + s * 1.8) + s * 40.0);
  float star = step(0.975, s) * smoothstep(1.6, 0.0, d) * twinkle * (1.0 - curtain);
  col += vec3(0.32, 0.34, 0.38) * star;

  fragColor = vec4(col, 1.0);
}

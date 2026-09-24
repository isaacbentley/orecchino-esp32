// measure_height.dart — reports a child's laid-out height after each layout
// that changes it (the Live header and the sheet's peek size themselves by it).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class MeasureHeight extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onHeight;

  const MeasureHeight({super.key, required this.onHeight, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderMeasureHeight).onHeight = onHeight;
}

class _RenderMeasureHeight extends RenderProxyBox {
  _RenderMeasureHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h != _last) {
      _last = h;
      SchedulerBinding.instance.addPostFrameCallback((_) => onHeight(h));
    }
  }
}

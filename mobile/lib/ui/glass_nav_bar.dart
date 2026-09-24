// glass_nav_bar.dart — the floating glass tab bar: four destinations, a
// light that slides to the selected one, 44 pt targets. Its labels follow
// the system text size up to 1.35x (as tab bars do); the screen reader
// always has the full words.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import 'glass.dart';
import 'theme/theme.dart';

class GlassNavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const GlassNavItem(this.icon, this.selectedIcon, this.label);
}

class GlassNavBar extends StatelessWidget {
  final List<GlassNavItem> items;
  final int index;
  final ValueChanged<int> onTap;

  /// Extra words for a destination (e.g. an alert on Live).
  final Map<int, String> badges;

  const GlassNavBar({super.key, required this.items, required this.index, required this.onTap, this.badges = const {}});

  static const double height = 64;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    // The bar owns the bottom of the screen: a fade to deep space behind it,
    // so scrolling content never shows in the gap beneath the floating bar.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            OrecchinoColors.void0.withValues(alpha: 0),
            OrecchinoColors.void0.withValues(alpha: 0.94),
            OrecchinoColors.void0,
          ],
          // Opaque from the bar's middle down: nothing shows beneath it.
          stops: const [0, 0.3, 0.55],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 18, 16, bottom > 0 ? bottom : 12),
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.35,
          child: Glass(
            borderRadius: BorderRadius.circular(32),
            blur: 28,
            shadows: const [BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, 10))],
            child: SizedBox(
              height: height,
              child: LayoutBuilder(builder: (context, box) {
                final w = box.maxWidth / items.length;
                return Stack(children: [
                  AnimatedPositioned(
                    duration: Motion.of(context, Motion.morph),
                    curve: Motion.springy,
                    left: w * index + 6,
                    top: 6,
                    width: w - 12,
                    height: height - 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            OrecchinoColors.aqua.withValues(alpha: 0.22),
                            OrecchinoColors.aqua.withValues(alpha: 0.08),
                          ],
                        ),
                        border: Border.all(color: OrecchinoColors.aqua.withValues(alpha: 0.35)),
                      ),
                    ),
                  ),
                  Row(children: [
                    for (var i = 0; i < items.length; i++)
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: i == index,
                          label: [items[i].label, if (badges[i] != null) badges[i]!].join(', '),
                          excludeSemantics: true,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(26),
                            onTap: () => onTap(i),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Stack(clipBehavior: Clip.none, children: [
                                  Icon(
                                    i == index ? items[i].selectedIcon : items[i].icon,
                                    size: 22,
                                    color: i == index ? OrecchinoColors.aqua : OrecchinoColors.inkMuted,
                                  ),
                                  if (badges[i] != null)
                                    const Positioned(
                                      right: -4,
                                      top: -2,
                                      child: _BadgeDot(),
                                    ),
                                ]),
                                const SizedBox(height: 3),
                                Text(
                                  items[i].label,
                                  maxLines: 1,
                                  style: OrecchinoType.caption.copyWith(
                                    fontSize: 11,
                                    fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                                    color: i == index ? OrecchinoColors.ink : OrecchinoColors.inkMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ]),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _BadgeDot extends StatelessWidget {
  const _BadgeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: OrecchinoColors.warning,
        shape: BoxShape.circle,
        border: Border.all(color: OrecchinoColors.void0, width: 1.5),
      ),
    );
  }
}

/// The same destinations as a floating vertical rail, for phones on their
/// side (the height is precious there; the width is not).
class GlassNavRail extends StatelessWidget {
  final List<GlassNavItem> items;
  final int index;
  final ValueChanged<int> onTap;
  final Map<int, String> badges;

  const GlassNavRail(
      {super.key, required this.items, required this.index, required this.onTap, this.badges = const {}});

  static const double width = 76;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.35,
      child: Glass(
        borderRadius: BorderRadius.circular(30),
        blur: 28,
        padding: const EdgeInsets.all(6),
        shadows: const [BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(6, 0))],
        child: SizedBox(
          width: width - 12,
          // Stretched: the selected pill spans the rail, wider than its label.
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < items.length; i++)
              Semantics(
                button: true,
                selected: i == index,
                label: [items[i].label, if (badges[i] != null) badges[i]!].join(', '),
                excludeSemantics: true,
                child: AnimatedContainer(
                  duration: Motion.of(context, Motion.base),
                  curve: Motion.standard,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    color: i == index ? OrecchinoColors.aqua.withValues(alpha: 0.16) : Colors.transparent,
                    border: Border.all(
                        color: i == index ? OrecchinoColors.aqua.withValues(alpha: 0.35) : Colors.transparent),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => onTap(i),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 60),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Stack(clipBehavior: Clip.none, children: [
                          Icon(
                            i == index ? items[i].selectedIcon : items[i].icon,
                            size: 22,
                            color: i == index ? OrecchinoColors.aqua : OrecchinoColors.inkMuted,
                          ),
                          if (badges[i] != null) const Positioned(right: -4, top: -2, child: _BadgeDot()),
                        ]),
                        const SizedBox(height: 3),
                        Text(
                          items[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: OrecchinoType.caption.copyWith(
                            fontSize: 10.5,
                            fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                            color: i == index ? OrecchinoColors.ink : OrecchinoColors.inkMuted,
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

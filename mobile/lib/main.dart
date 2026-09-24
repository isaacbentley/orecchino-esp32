// main.dart — Root entry point for Orecchino mobile application
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app_controller.dart';
import 'core/alerts/notifier.dart';
import 'core/traffic/traffic_rules.dart';
import 'data/db.dart';
import 'features/detectors/detectors_view.dart';
import 'features/find/find_view.dart';
import 'features/history/history_view.dart';
import 'features/live/contact_sheet.dart';
import 'features/live/live_view.dart';
import 'ui/glass_nav_bar.dart';
import 'ui/living_background.dart';
import 'ui/theme/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppController(db: AppDatabase(), alerts: SystemAlertSink());
  app.start();
  runApp(OrecchinoMobileApp(app: app));
}

class OrecchinoMobileApp extends StatelessWidget {
  final AppController app;

  const OrecchinoMobileApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orecchino',
      theme: OrecchinoTheme.dark,
      darkTheme: OrecchinoTheme.dark,
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      // Follow the system text size (Dynamic Type / font scale) up to 2x;
      // every screen scrolls or wraps rather than clipping.
      builder: (context, child) => MediaQuery.withClampedTextScaling(maxScaleFactor: 2.0, child: child!),
      home: MainShell(app: app),
    );
  }
}

class MainShell extends StatefulWidget {
  final AppController app;

  const MainShell({super.key, required this.app});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tabIndex = 0;

  // Tickers (the sky, the sweep, the lights) stop while the app is in the
  // background; the engine stops drawing frames then too, this makes it
  // explicit and covers the moment the app is hidden but not yet paused.
  bool _foreground = true;
  late final AppLifecycleListener _life = AppLifecycleListener(onStateChange: (s) {
    final fg = s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
    if (fg != _foreground && mounted) setState(() => _foreground = fg);
  });

  static const _items = [
    GlassNavItem(Icons.radar_outlined, Icons.radar_rounded, 'Live'),
    GlassNavItem(Icons.explore_outlined, Icons.explore_rounded, 'Find'),
    GlassNavItem(Icons.timeline_outlined, Icons.timeline_rounded, 'History'),
    GlassNavItem(Icons.sensors_outlined, Icons.sensors_rounded, 'Detectors'),
  ];

  @override
  void initState() {
    super.initState();
    // A notification's Show opens the Live sky on that pair.
    widget.app.showRequest.addListener(_onShow);
    _life; // start listening
  }

  void _onShow() {
    if (widget.app.showRequest.value != null && _tabIndex != 0) setState(() => _tabIndex = 0);
  }

  @override
  void dispose() {
    widget.app.showRequest.removeListener(_onShow);
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final items = buildLiveItems(app);
          final level = sceneLevel(items, app.traffic.result.highest);
          final Widget screen = switch (_tabIndex) {
            0 => LiveView(app: app),
            1 => FindView(app: app),
            2 => HistoryView(db: app.db, app: app),
            _ => DetectorsView(app: app),
          };
          // The badge on Live speaks the alert's own words.
          final alertText = app.traffic.result.alerts.isNotEmpty
              ? app.traffic.result.alerts.first.text
              : items.where((c) => !c.stale && c.alertWords.isNotEmpty).map((c) => c.alertWords.join(', ')).firstOrNull;
          final badges = {if (level >= TrafficLevel.caution && alertText != null && _tabIndex != 0) 0: alertText};
          final mq = MediaQuery.of(context);
          // A phone on its side: the tabs move to a rail on the left.
          final rail = mq.size.width > mq.size.height && mq.size.height < 600;
          final railInset = mq.padding.left + 8 + GlassNavRail.width + 4;
          Widget body = AnimatedSwitcher(
            duration: Motion.of(context, Motion.base),
            switchInCurve: Motion.emphasized,
            switchOutCurve: Motion.exit,
            // Every screen fills the shell (the default centres them).
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(anim), child: child),
            ),
            child: KeyedSubtree(key: ValueKey(_tabIndex), child: screen),
          );
          if (rail) {
            // Screens keep clear of the rail as they do of the notch.
            body = MediaQuery(data: mq.copyWith(padding: mq.padding.copyWith(left: railInset)), child: body);
          }
          return TickerMode(
            enabled: _foreground,
            child: Scaffold(
              backgroundColor: OrecchinoColors.void0,
              extendBody: true,
              body: Stack(children: [
                Positioned.fill(child: LivingBackground(level: level)),
                Positioned.fill(child: body),
                // A scrim under the status bar: content scrolls away beneath it.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: mq.padding.top + 18,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            OrecchinoColors.void0.withValues(alpha: 0.92),
                            OrecchinoColors.void0.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (rail)
                  Positioned(
                    left: mq.padding.left + 8,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: GlassNavRail(
                        items: _items,
                        index: _tabIndex,
                        onTap: (i) => setState(() => _tabIndex = i),
                        badges: badges,
                      ),
                    ),
                  ),
              ]),
              bottomNavigationBar: rail
                  ? null
                  : GlassNavBar(
                      items: _items,
                      index: _tabIndex,
                      onTap: (i) => setState(() => _tabIndex = i),
                      badges: badges,
                    ),
            ),
          );
        },
      ),
    );
  }
}

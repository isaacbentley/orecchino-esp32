// main.dart — Root entry point for Orecchino mobile application
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'app/app_controller.dart';
import 'core/alerts/notifier.dart';
import 'core/power/power_policy.dart';
import 'core/traffic/traffic_rules.dart';
import 'data/db.dart';
import 'features/detectors/detectors_view.dart';
import 'features/find/find_view.dart';
import 'features/history/history_view.dart';
import 'features/live/contact_sheet.dart';
import 'features/live/live_view.dart';
import 'ui/ambient_clock.dart';
import 'ui/glass.dart';
import 'ui/glass_nav_bar.dart';
import 'ui/living_background.dart';
import 'ui/theme/theme.dart';
import 'ui/traffic_widgets.dart';

/// On screen: resumed, or inactive (a system sheet over the app, the app
/// switcher). Paused, hidden, detached, or not yet known (a headless start:
/// Android waking the app for an associated detector, iOS relaunching it in
/// the background for Bluetooth) is not; the lifecycle listener in
/// [MainShell] reports the change when a screen does open.
bool lifecycleForeground(AppLifecycleState? s) => s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

void main() {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // iOS: opt into Core Bluetooth state restoration before anything else
  // touches Bluetooth, so a connection (or a pending connect) to the
  // detector survives iOS ending the app in the background, and iOS
  // relaunches it when the detector connects.
  if (!kIsWeb && Platform.isIOS) unawaited(FlutterBluePlus.setOptions(restoreState: true));
  final db = AppDatabase();
  final app = AppController.platform(
    db: db,
    alerts: SystemAlertSink(),
    foreground: lifecycleForeground(binding.lifecycleState),
  );
  // The look first, so a Flat app never flashes the Sky while it starts.
  db.getSetting('look').then((v) => Look.apply(AppLook.parse(v)), onError: (Object _) {}).whenComplete(() {
    app.start();
    runApp(OrecchinoMobileApp(app: app));
  });
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
      // every screen scrolls or wraps rather than clipping. The power
      // policy sets how the glass frosts and whether ambient motion runs,
      // for every route (sheets and dialogs too).
      builder: (context, child) => ValueListenableBuilder<PowerPolicy>(
        valueListenable: app.power,
        builder: (context, p, _) => GlassScope(
          mode: p.glass,
          // Flat has no ambient motion at all (no sweep, pulses or glows).
          child: AmbientMotion(
            enabled: p.ambientHz > 0 && !Look.flat,
            child: MediaQuery.withClampedTextScaling(maxScaleFactor: 2.0, child: child!),
          ),
        ),
      ),
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

  // The app in the foreground or not: tickers stop (TickerMode), the
  // ambient clock pauses, and the app's power policy follows (the compass,
  // location, the phone's scan, ADS-B). "inactive" (a system sheet over the
  // app, the app switcher) still counts as in front. It starts as the app
  // does (main reads the lifecycle state; the tests' controllers start in
  // front), then follows the lifecycle; the listener reports changes only,
  // so a state known by the time the shell is built is read once too.
  late bool _foreground = widget.app.foreground;
  bool? _reduced;
  late final AppLifecycleListener _life = AppLifecycleListener(onStateChange: _onLifecycle);

  void _onLifecycle(AppLifecycleState s) {
    final fg = lifecycleForeground(s);
    AmbientClock.instance.paused = !fg;
    widget.app.setVisibility(foreground: fg);
    if (fg != _foreground && mounted) setState(() => _foreground = fg);
  }

  // The shell rebuilds only when what it shows changes (the scene level
  // and the Live badge), not on every update of the app: each screen
  // listens for itself.
  TrafficLevel _level = TrafficLevel.none;
  String? _alertText;

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
    widget.app.notice.addListener(_onNotice);
    widget.app.addListener(_onApp);
    widget.app.power.addListener(_onPower);
    _life; // start listening
    // A change between main() and this build (the activity resumed while
    // the settings loaded) has no listener yet: read the state once.
    final s = WidgetsBinding.instance.lifecycleState;
    if (s != null && lifecycleForeground(s) != _foreground) _onLifecycle(s);
    _onApp();
    _onPower();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = Motion.reduced(context);
    if (r != _reduced) {
      _reduced = r;
      // Not during the build: the policy's listeners rebuild the app.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.app.setVisibility(reduceMotion: r);
      });
    }
  }

  PowerPolicy? _power;

  /// The policy changed: the ambient rate, and (for the shell) the glass
  /// grouping and the aurora's scale.
  void _onPower() {
    final p = widget.app.powerPolicy;
    if (p.ambientHz > 0) AmbientClock.instance.hz = p.ambientHz;
    final old = _power;
    _power = p;
    if (old != null && mounted && (old.glass != p.glass || old.auroraScale != p.auroraScale)) setState(() {});
  }

  /// The scene level and the badge's words; a rebuild only when they change.
  void _onApp() {
    final app = widget.app;
    final items = buildLiveItems(app);
    final level = sceneLevel(items, app.traffic.result.highest);
    // The badge on Live speaks the alert's own words, its action first.
    final alertText = app.traffic.result.alerts.isNotEmpty
        ? trafficAction(app.traffic.result.alerts.first)
        : items.where((c) => !c.stale && c.alertWords.isNotEmpty).map((c) => c.alertWords.join(', ')).firstOrNull;
    if (level == _level && alertText == _alertText) return;
    if (!mounted) return;
    setState(() {
      _level = level;
      _alertText = alertText;
    });
  }

  void _selectTab(int i) {
    setState(() => _tabIndex = i);
    widget.app.setVisibility(tab: AppTab.values[i]);
  }

  /// A short notice from the app ("History cleared on T5"): a floating
  /// glass bar, read out by the screen reader.
  void _onNotice() {
    final text = widget.app.notice.value;
    if (text == null || !mounted) return;
    widget.app.notice.value = null;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text, style: OrecchinoType.bodyStrong),
        behavior: SnackBarBehavior.floating,
        backgroundColor: OrecchinoColors.raised,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16), side: BorderSide(color: OrecchinoColors.lineBright)),
        duration: const Duration(seconds: 4),
      ));
  }

  void _onShow() {
    if (widget.app.showRequest.value != null && _tabIndex != 0) _selectTab(0);
  }

  @override
  void dispose() {
    widget.app.showRequest.removeListener(_onShow);
    widget.app.notice.removeListener(_onNotice);
    widget.app.removeListener(_onApp);
    widget.app.power.removeListener(_onPower);
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Builder(
        builder: (context) {
          final level = _level;
          final alertText = _alertText;
          // Each screen rebuilds with the app's updates (once a second, and
          // on real changes); the shell around it does not.
          final Widget screen = ListenableBuilder(
            listenable: app,
            builder: (context, _) => switch (_tabIndex) {
              0 => LiveView(app: app),
              1 => FindView(app: app),
              2 => HistoryView(db: app.db, app: app),
              _ => DetectorsView(app: app),
            },
          );
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
          // Balanced: the screen's glass panels share one backdrop read.
          if (app.powerPolicy.glass == GlassMode.grouped) body = BackdropGroup(child: body);
          return TickerMode(
            enabled: _foreground,
            child: Scaffold(
              backgroundColor: OrecchinoColors.void0,
              extendBody: true,
              body: Stack(children: [
                Positioned.fill(child: LivingBackground(level: level, renderScale: app.powerPolicy.auroraScale)),
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
                        onTap: _selectTab,
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
                      onTap: _selectTab,
                      badges: badges,
                    ),
            ),
          );
        },
      ),
    );
  }
}

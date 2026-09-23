// main.dart — Root entry point for Orecchino mobile application
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'core/alerts/notifier.dart';
import 'data/db.dart';
import 'features/detectors/detectors_view.dart';
import 'features/find/find_view.dart';
import 'features/history/history_view.dart';
import 'features/live/live_view.dart';
import 'ui/theme.dart';

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
      theme: OrecchinoTheme.darkTheme,
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

  @override
  void initState() {
    super.initState();
    // A notification's Show opens the Live radar on that pair.
    widget.app.showRequest.addListener(_onShow);
  }

  void _onShow() {
    if (widget.app.showRequest.value != null && _tabIndex != 0) setState(() => _tabIndex = 0);
  }

  @override
  void dispose() {
    widget.app.showRequest.removeListener(_onShow);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final Widget screen = switch (_tabIndex) {
          0 => LiveView(app: app),
          1 => FindView(app: app),
          2 => HistoryView(db: app.db),
          _ => DetectorsView(app: app),
        };
        return Scaffold(
          body: screen,
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _tabIndex,
            onTap: (i) => setState(() => _tabIndex = i),
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.radar), label: 'Live'),
              BottomNavigationBarItem(icon: Icon(Icons.navigation), label: 'Find'),
              BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History'),
              BottomNavigationBarItem(icon: Icon(Icons.bluetooth), label: 'Detectors'),
            ],
          ),
        );
      },
    );
  }
}

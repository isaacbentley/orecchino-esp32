// clear_history_sheet.dart — "Clear history…" (History's header, and a
// detector's card): three explicit choices, each saying what it deletes and
// that it cannot be undone.
//
// - Clear this phone's history: every record on this phone, from every
//   detector; pins, sync cursors and settings stay.
// - Clear history on <detector>: only with a verified detector connected;
//   sends {"cmd":"log_clear"} and waits up to 5 s for its log_cleared
//   (the app then starts a new log epoch for it; this phone's records stay).
// - Clear both: the detector first; the phone's records go only if the
//   detector confirmed.
// A stray tap does nothing: a choice's button asks again in place ("This
// can't be undone"), and only the second, red button deletes.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../ui/glass.dart';
import '../../ui/theme/theme.dart';

enum ClearChoice { phone, detector, both }

class ClearHistorySheet extends StatefulWidget {
  final AppController app;

  const ClearHistorySheet({super.key, required this.app});

  static Future<void> show(BuildContext context, AppController app) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: const Color(0x99020409),
        builder: (_) => Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Glass(
              blur: 32,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
              child: ClearHistorySheet(app: app),
            ),
          ),
        ),
      );

  @override
  State<ClearHistorySheet> createState() => ClearHistorySheetState();
}

class ClearHistorySheetState extends State<ClearHistorySheet> {
  ClearChoice? _confirming;
  ClearChoice? _busy;
  String? _result;
  bool _failed = false;

  AppController get app => widget.app;

  Future<void> _run(ClearChoice c) async {
    setState(() {
      _busy = c;
      _confirming = null;
      _result = null;
      _failed = false;
    });
    String? error;
    int? deleted;
    final name = app.connectedDetectorName ?? 'the detector';
    if (c != ClearChoice.phone) error = await app.clearDetectorHistory();
    if (error == null && c != ClearChoice.detector) deleted = await app.clearPhoneHistory();
    if (!mounted) return;
    setState(() {
      _busy = null;
      _failed = error != null;
      _result = error != null
          ? (c == ClearChoice.both ? '$error. This phone\'s history was kept.' : error)
          : [
              if (c != ClearChoice.phone) 'History cleared on $name.',
              if (deleted != null) 'Deleted $deleted record${deleted == 1 ? '' : 's'} from this phone.',
            ].join(' ');
    });
  }

  @override
  Widget build(BuildContext context) {
    final connected = app.detectorReady && app.connectedDetectorId != null;
    final name = app.connectedDetectorName ?? 'the detector';
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 40,
              height: 5,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: OrecchinoColors.lineBright, borderRadius: BorderRadius.circular(3)),
            ),
          ),
          Row(children: [
            Icon(Icons.delete_sweep_rounded, color: OrecchinoColors.warning, size: 24),
            const SizedBox(width: 10),
            Expanded(child: Semantics(header: true, child: Text('Clear history', style: OrecchinoType.heading))),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: Text('Choose what to delete. Deleted history cannot be recovered.', style: OrecchinoType.label),
          ),
          // The outcome first, where it is seen without scrolling.
          if (_result != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4, right: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(_failed ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
                      size: 20, color: _failed ? OrecchinoColors.warning : OrecchinoColors.ok),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_result!,
                        style: OrecchinoType.bodyStrong
                            .copyWith(color: _failed ? OrecchinoColors.warning : OrecchinoColors.ok)),
                  ),
                ]),
              ),
            ),
          _choice(
            ClearChoice.phone,
            title: 'Clear this phone\'s history',
            detail: 'Deletes every record stored on this phone, from every detector. Paired detectors and '
                'settings stay; the detectors keep their own logs. This can\'t be undone.',
            enabled: true,
          ),
          _choice(
            ClearChoice.detector,
            title: 'Clear history on $name',
            detail: connected
                ? 'Deletes the match log held on $name. This phone\'s copy stays, and the next sync starts '
                    'from the detector\'s new, empty log. This can\'t be undone.'
                : 'Connect a paired, verified detector to clear its log.',
            enabled: connected,
          ),
          _choice(
            ClearChoice.both,
            title: 'Clear both',
            detail: connected
                ? 'Deletes the log on $name, then every record on this phone (only if $name confirms). '
                    'This can\'t be undone.'
                : 'Needs a connected detector.',
            enabled: connected,
          ),
        ]),
      ),
    );
  }

  Widget _choice(ClearChoice c, {required String title, required String detail, required bool enabled}) {
    final confirming = _confirming == c;
    final busy = _busy == c;
    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 8),
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.base),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: confirming ? OrecchinoColors.warning.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: confirming ? OrecchinoColors.warning.withValues(alpha: 0.7) : OrecchinoColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title,
              style:
                  OrecchinoType.bodyStrong.copyWith(color: enabled ? OrecchinoColors.ink : OrecchinoColors.inkSubtle)),
          const SizedBox(height: 3),
          Text(detail, style: OrecchinoType.caption),
          const SizedBox(height: 10),
          if (busy)
            Row(children: [
              const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: 'Clearing')),
              const SizedBox(width: 10),
              Text(c == ClearChoice.phone ? 'Deleting…' : 'Waiting for the detector…', style: OrecchinoType.label),
            ])
          else if (confirming)
            Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('This can\'t be undone.',
                  style: OrecchinoType.label.copyWith(color: OrecchinoColors.warning, fontWeight: FontWeight.w700)),
              TextButton(
                onPressed: () => setState(() => _confirming = null),
                style: TextButton.styleFrom(minimumSize: const Size(64, OrecchinoTheme.minTarget)),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                key: ValueKey('confirm-${c.name}'),
                onPressed: () => _run(c),
                icon: const Icon(Icons.delete_forever_rounded, size: 18),
                label: Text(switch (c) {
                  ClearChoice.phone => 'Delete phone history',
                  ClearChoice.detector => 'Delete detector history',
                  ClearChoice.both => 'Delete both',
                }),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, OrecchinoTheme.minTarget),
                  backgroundColor: OrecchinoColors.warning,
                  foregroundColor: OrecchinoColors.void0,
                ),
              ),
            ])
          else
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: ValueKey('choose-${c.name}'),
                onPressed: !enabled || _busy != null ? null : () => setState(() => _confirming = c),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, OrecchinoTheme.minTarget),
                  foregroundColor: OrecchinoColors.warning,
                  side: BorderSide(
                      color: enabled ? OrecchinoColors.warning.withValues(alpha: 0.6) : OrecchinoColors.line),
                ),
                child: const Text('Clear…'),
              ),
            ),
        ]),
      ),
    );
  }
}

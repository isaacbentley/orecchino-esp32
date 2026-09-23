// history_view.dart — Durable flight history timeline, filters and export
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import '../../core/protocol/messages.dart';
import '../../data/db.dart';
import '../../ui/theme.dart';

class HistoryView extends StatefulWidget {
  final AppDatabase db;

  const HistoryView({super.key, required this.db});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  String _filter = '';
  bool _onlyAlerts = false;
  late final Stream<List<DetectionEntry>> _records = widget.db.watchDetections();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HISTORY LOG'),
        actions: [
          IconButton(
            tooltip: _onlyAlerts ? 'Show all records' : 'Show alerts only',
            isSelected: _onlyAlerts,
            icon: Icon(
              Icons.warning_amber_rounded,
              color: _onlyAlerts ? OrecchinoTheme.danger : OrecchinoTheme.muted,
            ),
            onPressed: () => setState(() => _onlyAlerts = !_onlyAlerts),
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'Search UAS ID or MAC...',
                hintStyle: const TextStyle(color: OrecchinoTheme.subtle, fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 18, color: OrecchinoTheme.muted),
                filled: true,
                fillColor: OrecchinoTheme.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: OrecchinoTheme.border),
                ),
              ),
              onChanged: (val) => setState(() => _filter = val.trim().toLowerCase()),
            ),
          ),

          // Log list
          Expanded(
            child: StreamBuilder<List<DetectionEntry>>(
              stream: _records,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                var list = snapshot.data!;
                if (_onlyAlerts) {
                  list = list.where((d) => d.emerg || d.tfr || d.authState == AuthState.invalid).toList();
                }
                if (_filter.isNotEmpty) {
                  list = list.where((d) =>
                      (d.uasId != null && d.uasId!.toLowerCase().contains(_filter)) ||
                      d.mac.toLowerCase().contains(_filter)).toList();
                }

                if (list.isEmpty) {
                  return const Center(
                    child: Text(
                      'NO HISTORY RECORDS',
                      style: TextStyle(color: OrecchinoTheme.muted, fontFamily: 'monospace'),
                    ),
                  );
                }

                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: OrecchinoTheme.border),
                  itemBuilder: (context, idx) {
                    final d = list[idx];
                    final date = DateTime.fromMillisecondsSinceEpoch(d.lastUtc * 1000, isUtc: true);
                    final timeStr = d.lastUtc == 0
                        ? 'no clock'
                        : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}Z';
                    final words = [
                      if (d.active) 'LIVE',
                      if (d.emerg) 'EMERGENCY REPORTED',
                      if (d.tfr) 'IN TFR',
                      if (AuthState.words(d.authState) != null) AuthState.words(d.authState)!,
                    ];

                    return ListTile(
                      dense: true,
                      leading: Icon(
                        d.emerg ? Icons.warning_rounded : (d.tfr ? Icons.block : Icons.flight),
                        color: d.emerg ? OrecchinoTheme.danger : (d.tfr ? OrecchinoTheme.amber : OrecchinoTheme.accent),
                        size: 18,
                      ),
                      title: Text(
                        d.uasId ?? d.mac,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                      subtitle: Text(
                        [
                          ...words,
                          d.seq == null ? 'still in range' : 'record ${d.seq}',
                          '${d.durS} s',
                          if (d.peakRssi != null) 'peak ${d.peakRssi} dBm',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted, fontFamily: 'monospace'),
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            timeStr,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            ),
                          ),
                          Text(
                            d.maxH != null ? 'max ${d.maxH!.round()} m' : 'height unknown',
                            style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

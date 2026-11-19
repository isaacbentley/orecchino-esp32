// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/droneguide/droneguide.dart';
import '../../ui/theme/theme.dart';

const droneguideColor = Color(0xFFC6B8FF);
final _officialMap = Uri.https('map.droneguide.be');

String droneguideSummary(DroneguideService service) {
  final snapshot = service.snapshot;
  if (service.loading) return 'Updating geozones…';
  if (snapshot == null) return service.error == null ? 'No data loaded' : 'Geozones unavailable';
  if (!service.layerEnabled) return 'Layer hidden';
  final shown = service.visibleZones.length;
  if (service.activeOnly) return '$shown active ${shown == 1 ? 'geozone' : 'geozones'}';
  return '$shown ${shown == 1 ? 'geozone' : 'geozones'}';
}

String _date(BuildContext context, DateTime instant) {
  final local = instant.toLocal();
  final format = MaterialLocalizations.of(context);
  return '${format.formatShortDate(local)} ${format.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

String _source(DroneguideSnapshot snapshot) => snapshot.source == 'live'
    ? 'skeyes Droneguide online'
    : 'Droneguide JSON import${snapshot.sourceName == null ? '' : ' · ${snapshot.sourceName}'}';

/// The same controls are available in Detectors settings and directly from
/// the map, so someone can change the layer without leaving Live.
Future<void> showDroneguideOptions(
  BuildContext context,
  DroneguideService service, {
  VoidCallback? onFit,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.86,
        child: _DroneguideOptions(service: service, onFit: onFit),
      ),
    );

class DroneguideSettingsTile extends StatelessWidget {
  final DroneguideService service;

  const DroneguideSettingsTile({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Belgian geozones · Droneguide', style: OrecchinoType.bodyStrong),
        subtitle: Text(droneguideSummary(service), style: OrecchinoType.caption),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => showDroneguideOptions(context, service),
      ),
    );
  }
}

class _DroneguideOptions extends StatefulWidget {
  final DroneguideService service;
  final VoidCallback? onFit;

  const _DroneguideOptions({required this.service, this.onFit});

  @override
  State<_DroneguideOptions> createState() => _DroneguideOptionsState();
}

class _DroneguideOptionsState extends State<_DroneguideOptions> {
  static const _types = XTypeGroup(
    label: 'Droneguide JSON',
    extensions: ['json', 'geojson'],
    mimeTypes: ['application/json', 'application/geo+json', 'application/octet-stream'],
    uniformTypeIdentifiers: ['public.json', 'org.geojson.geojson'],
  );

  bool _openingFile = false;
  String? _controlError;

  DroneguideService get _service => widget.service;

  Future<void> _pickFile() async {
    setState(() {
      _openingFile = true;
      _controlError = null;
    });
    try {
      final file = await openFile(acceptedTypeGroups: const [_types]);
      if (!mounted || file == null) return;
      if (await file.length() > droneguideMaxBytes) {
        throw const FormatException('Choose a Droneguide JSON file up to ${droneguideMaxBytes ~/ (1024 * 1024)} MiB.');
      }
      final bytes = await file.readAsBytes();
      if (mounted) await _service.importBytes(bytes, filename: file.name);
    } on FormatException catch (error) {
      if (mounted) setState(() => _controlError = error.message);
    } catch (_) {
      if (mounted) setState(() => _controlError = 'Could not open the Droneguide file.');
    } finally {
      if (mounted) setState(() => _openingFile = false);
    }
  }

  Future<void> _openOfficialMap() async {
    try {
      if (await launchUrl(_officialMap, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // The device could not open a browser.
    }
    if (mounted) {
      setState(() => _controlError = 'Open map.droneguide.be in a browser.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final data = _service.snapshot;
        return ListView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.paddingOf(context).bottom + 24),
          children: [
            Semantics(header: true, child: Text('Belgian geozones', style: OrecchinoType.title)),
            Text('Droneguide · skeyes · Surface to 500 ft AGL', style: OrecchinoType.label),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Show layer on the map', style: OrecchinoType.bodyStrong),
              value: _service.layerEnabled,
              onChanged: _service.setLayerEnabled,
            ),
            Text('Zones shown', style: OrecchinoType.bodyStrong),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: const Text('All zones'),
                  selected: !_service.activeOnly,
                  onSelected: (_) => _service.setActiveOnly(false),
                ),
                ChoiceChip(
                  label: const Text('Active only'),
                  selected: _service.activeOnly,
                  onSelected: (_) => _service.setActiveOnly(true),
                ),
              ],
            ),
            Text('Active only hides zones whose activity is unknown or inactive.', style: OrecchinoType.caption),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Live Droneguide data', style: OrecchinoType.bodyStrong),
              subtitle: Text(
                'Download the official Belgian feed while the app is open.',
                style: OrecchinoType.caption,
              ),
              value: _service.autoRefresh,
              onChanged: _service.setAutoRefresh,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: _service.autoRefresh && !_service.loading ? _service.refresh : null,
                  child: const Text('Refresh now'),
                ),
                OutlinedButton(
                  onPressed: _openingFile || _service.loading ? null : _pickFile,
                  child: const Text('Import Droneguide JSON'),
                ),
                if (widget.onFit != null)
                  OutlinedButton(
                    onPressed: _service.visibleZones.isEmpty
                        ? null
                        : () {
                            Navigator.pop(context);
                            widget.onFit!();
                          },
                    child: const Text('Fit geozones on map'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(droneguideSummary(_service), style: OrecchinoType.bodyStrong),
                  if (data != null) ...[
                    Text(_source(data), style: OrecchinoType.caption),
                    Text('Loaded ${_date(context, data.fetchedAt)}', style: OrecchinoType.caption),
                    if (data.snapshotAt case final time?)
                      Text('Activity snapshot ${_date(context, time)}', style: OrecchinoType.caption),
                    if (_service.stale)
                      Text(
                        'Live activity data is out of date.',
                        style: OrecchinoType.caption.copyWith(color: OrecchinoColors.caution),
                      ),
                    if (data.skipped > 0) Text('${data.skipped} zones skipped', style: OrecchinoType.caption),
                    if (data.unknownAltitudeCount > 0)
                      Text('${data.unknownAltitudeCount} zones with unconfirmed altitude limits',
                          style: OrecchinoType.caption),
                  ],
                  if (_service.error case final error?)
                    Text(error, style: OrecchinoType.caption.copyWith(color: OrecchinoColors.caution)),
                  if (_controlError case final error?)
                    Text(error, style: OrecchinoType.caption.copyWith(color: OrecchinoColors.caution)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: _openOfficialMap, child: const Text('Open official Droneguide map')),
            ),
          ],
        );
      },
    );
  }
}

Future<void> showDroneguideZones(
  BuildContext context,
  DroneguideService service,
  List<DroneguideZone> zones,
) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: zones.length > 1 ? 0.8 : 0.65,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Semantics(
              header: true,
              child: Text(
                zones.length == 1 ? 'Belgian geozone' : '${zones.length} overlapping Belgian geozones',
                style: OrecchinoType.title,
              ),
            ),
            Text('Source: Droneguide · skeyes', style: OrecchinoType.label),
            for (final zone in zones) ...[
              const Divider(),
              _ZoneDetails(service: service, zone: zone),
            ],
          ],
        ),
      ),
    );

class _ZoneDetails extends StatelessWidget {
  final DroneguideService service;
  final DroneguideZone zone;

  const _ZoneDetails({required this.service, required this.zone});

  String _limit(double? amount, String unit, String reference) {
    if (amount == null) return 'Unknown';
    final magnitude = amount == amount.roundToDouble() ? amount.toStringAsFixed(0) : amount.toString();
    return [magnitude, if (unit.isNotEmpty) unit, if (reference.isNotEmpty) reference].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final activity = service.activityFor(zone);
    final restriction = switch (zone.restriction) {
      'PROHIBITED' => 'Prohibited',
      'REQ_AUTHORISATION' => 'Authorisation required',
      'CONDITIONAL' => 'Conditions apply',
      'NO_RESTRICTION' => 'No restriction listed',
      final value when value.isNotEmpty => value,
      _ => 'Unspecified',
    };
    final fields = <(String, String)>[
      ('Activity', switch (activity) {  true => 'Active', false => 'Inactive', null => 'Unknown'}),
      ('Restriction', restriction),
      if (zone.lower != null || zone.upper != null)
        (
          'Altitude',
          '${_limit(zone.lower, zone.lowerUnit, zone.lowerReference)} to '
              '${_limit(zone.upper, zone.upperUnit, zone.upperReference)}'
        ),
      if (zone.id.isNotEmpty) ('Identifier', zone.id),
      if (zone.validFrom.isNotEmpty) ('From', zone.validFrom),
      if (zone.validUntil.isNotEmpty) ('Until', zone.validUntil),
      if (zone.schedule.isNotEmpty) ('Schedule', zone.schedule),
      if (zone.reason.isNotEmpty) ('Reason', zone.reason),
      if (zone.message.isNotEmpty) ('Published message', zone.message),
      if (zone.conditions.isNotEmpty) ('Conditions', zone.conditions.join('\n')),
      if (zone.authorities.isNotEmpty) ('Authorities', zone.authorities.join('\n')),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(zone.name, style: OrecchinoType.bodyStrong.copyWith(color: droneguideColor)),
        ),
        for (final (label, value) in fields)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text.rich(TextSpan(
              style: OrecchinoType.body,
              children: [TextSpan(text: '$label · ', style: OrecchinoType.caption), TextSpan(text: value)],
            )),
          ),
      ],
    );
  }
}

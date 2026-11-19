// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
part of 'droneguide.dart';

const droneguideRefreshInterval = Duration(minutes: 15);
const droneguideFreshness = Duration(minutes: 30);
const _wfsPageSize = 2000;
const _wfsMaxPages = 12;
const _wfsWindow = Duration(hours: 24);
const _maxCacheBytes = 4 * droneguideMaxBytes + 64 * 1024;
const _wfsAltitudeFilter = "type_code <> 'TIME_ZONE' AND ("
    'lower_limit_altitude_meter_agl IS NULL OR upper_limit_altitude_meter_agl IS NULL OR '
    'lower_limit_altitude_meter_agl > upper_limit_altitude_meter_agl OR '
    "((lower_limit_altitude_meter_agl <= 152.4 OR lower_limit_reference IN ('AGL','GND','SFC')) AND "
    "(upper_limit_altitude_meter_agl >= 0 OR upper_limit_reference IN ('AGL','GND','SFC'))))";

class _Dataset {
  final String raw;
  final DroneguideSnapshot snapshot;

  const _Dataset(this.raw, this.snapshot);

  _Json get disk => {
        'data': raw,
        'fetchedAt': snapshot.fetchedAt.toIso8601String(),
        'snapshotAt': snapshot.snapshotAt?.toIso8601String(),
        'sourceName': snapshot.sourceName,
      };
}

class _Configuration {
  final bool layerEnabled;
  final bool autoRefresh;
  final bool activeOnly;
  final _Dataset? imported;
  final _Dataset? live;

  const _Configuration({
    this.layerEnabled = true,
    this.autoRefresh = false,
    this.activeOnly = false,
    this.imported,
    this.live,
  });

  _Configuration withChanges({
    bool? layerEnabled,
    bool? autoRefresh,
    bool? activeOnly,
    _Dataset? imported,
    _Dataset? live,
  }) =>
      _Configuration(
        layerEnabled: layerEnabled ?? this.layerEnabled,
        autoRefresh: autoRefresh ?? this.autoRefresh,
        activeOnly: activeOnly ?? this.activeOnly,
        imported: imported ?? this.imported,
        live: live ?? this.live,
      );

  _Json get disk => {
        'version': 1,
        'layerEnabled': layerEnabled,
        'autoRefresh': autoRefresh,
        'activeOnly': activeOnly,
        'imported': imported?.disk,
        'live': live?.disk,
      };
}

/// Loads the Droneguide overlay and keeps the last valid online and imported
/// datasets separately. No network request is made before live access is
/// enabled by the user.
class DroneguideService extends ChangeNotifier {
  DroneguideService({
    http.Client? client,
    Uri? endpoint,
    bool persistent = true,
    Future<File> Function()? storageFile,
    DateTime Function()? now,
  })  : _client = client,
        _ownsClient = client == null,
        _endpoint = endpoint ?? Uri.https('map.droneguide.be', '/ows'),
        _storage = persistent ? storageFile ?? _defaultFile : null,
        _now = now ?? DateTime.now;

  http.Client? _client;
  final bool _ownsClient;
  final Uri _endpoint;
  final Future<File> Function()? _storage;
  final DateTime Function() _now;
  _Configuration _config = const _Configuration();
  Future<void>? _initialized;
  Future<void> _pendingWrite = Future<void>.value();
  Timer? _ticker;
  DateTime? _lastAttempt;
  Completer<void>? _request;
  String? _error;
  bool _failedRefresh = false;
  bool _importing = false;
  bool _foreground = true;
  bool _disposed = false;
  List<bool?> _lastActivities = const [];
  bool _wasStale = false;

  bool get layerEnabled => _config.layerEnabled;
  bool get autoRefresh => _config.autoRefresh;
  bool get activeOnly => _config.activeOnly;
  bool get loading => _request != null || _importing;
  String? get error => _error;

  DroneguideSnapshot? get snapshot {
    final local = _config.imported;
    final online = _config.live;
    return ((autoRefresh || local == null) ? online ?? local : local)?.snapshot;
  }

  bool get stale => _isStale(snapshot, _now());

  bool _isStale(DroneguideSnapshot? snapshot, DateTime now) {
    final at = snapshot?.snapshotAt;
    if (at == null) return autoRefresh && _failedRefresh;
    final age = now.difference(at);
    return !autoRefresh ||
        _failedRefresh ||
        age.isNegative ||
        age >= droneguideFreshness;
  }

  bool? activityFor(DroneguideZone zone) =>
      _activityAt(zone, snapshot, _now(), stale);

  bool? _activityAt(
    DroneguideZone zone,
    DroneguideSnapshot? snapshot,
    DateTime now,
    bool stale,
  ) {
    if (snapshot == null) return null;
    if (snapshot.source == 'live') return stale ? null : zone.activity;
    return _importActivity(zone, now);
  }

  List<DroneguideZone> get visibleZones {
    final current = snapshot;
    if (!layerEnabled || current == null) return const [];
    if (!activeOnly) return current.zones;
    final now = _now();
    final stale = _isStale(current, now);
    return [
      for (final zone in current.zones)
        if (_activityAt(zone, current, now, stale) == true) zone,
    ];
  }

  static Future<File> _defaultFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(path.join(directory.path, 'droneguide-state.json'));
  }

  Future<void> initialize() => _initialized ??= _load();

  Future<void> _load() async {
    try {
      final file = await _storage?.call();
      if (file != null && await file.exists()) {
        if (await file.length() > _maxCacheBytes) {
          throw const FormatException('The Droneguide cache is too large.');
        }
        final disk = _object(_decode(await file.readAsString()));
        if (disk['version'] != 1) {
          throw const FormatException('Unknown Droneguide cache format.');
        }
        final imported = await _restoreDataset(disk['imported'], false);
        final live = await _restoreDataset(disk['live'], true);
        if (_disposed) return;
        _config = _Configuration(
          layerEnabled: disk['layerEnabled'] != false,
          autoRefresh: disk['autoRefresh'] == true,
          activeOnly: disk['activeOnly'] == true,
          imported: imported,
          live: live,
        );
      }
    } on Exception catch (error) {
      _error = 'Could not load saved Droneguide data. ${_message(error)}';
    }
    if (_disposed) return;
    _updateTimer();
    _changed();
    if (autoRefresh && _foreground) unawaited(refresh());
  }

  Future<_Dataset?> _restoreDataset(Object? data, bool live) async {
    if (data == null) return null;
    try {
      final disk = _object(data);
      final raw = disk['data'];
      final fetchedAt = DateTime.tryParse(_string(disk['fetchedAt']));
      final snapshotAt = DateTime.tryParse(_string(disk['snapshotAt']));
      if (raw is! String ||
          utf8.encode(raw).length > droneguideMaxBytes ||
          fetchedAt == null ||
          (snapshotAt != null) != live) {
        throw const FormatException('Invalid saved Droneguide dataset.');
      }
      return await _datasetFromRaw(
        raw,
        fetchedAt: fetchedAt,
        snapshotAt: snapshotAt,
        filename: _string(disk['sourceName']),
      );
    } on Exception catch (error) {
      _error = 'Could not load saved Droneguide data. ${_message(error)}';
      return null;
    }
  }

  Future<_Dataset> _datasetFromRaw(
    String raw, {
    required DateTime fetchedAt,
    DateTime? snapshotAt,
    String? filename,
  }) async {
    final parsed =
        await compute(_parseZones, (raw: raw, live: snapshotAt != null));
    return _Dataset(
        raw,
        DroneguideSnapshot(
          source: snapshotAt == null ? 'import' : 'live',
          fetchedAt: fetchedAt,
          snapshotAt: snapshotAt,
          sourceName: filename?.isEmpty == true ? null : filename,
          zones: parsed.zones,
          skipped: parsed.skipped,
          unknownAltitudeCount: parsed.unknown,
        ));
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pendingWrite.then((_) => operation());
    _pendingWrite =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _persist(_Configuration config) async {
    final file = await _storage?.call();
    if (file == null) return;
    final raw = utf8.encode(jsonEncode(config.disk));
    if (raw.length > _maxCacheBytes) {
      throw const FormatException('The Droneguide cache would be too large.');
    }
    await file.parent.create(recursive: true);
    // Settings and both datasets share one atomic update. A failed import
    // or refresh leaves the previous cache and settings intact.
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsBytes(raw, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> setLayerEnabled(bool enabled) =>
      _changePreference(() => _config.withChanges(layerEnabled: enabled));

  Future<void> setActiveOnly(bool activeOnly) =>
      _changePreference(() => _config.withChanges(activeOnly: activeOnly));

  Future<void> _changePreference(_Configuration Function() next) async {
    await initialize();
    await _serialized(() async {
      if (_disposed) return;
      final updated = next();
      try {
        await _persist(updated);
        if (_disposed) return;
        _config = updated;
        _updateTimer();
      } on Exception catch (error) {
        _error = 'Could not save the Droneguide setting. ${_message(error)}';
      }
      _changed();
    });
  }

  Future<void> setAutoRefresh(bool enabled) async {
    await initialize();
    await _serialized(() async {
      if (_disposed || enabled == autoRefresh) return;
      try {
        final updated = _config.withChanges(autoRefresh: enabled);
        await _persist(updated);
        if (_disposed) return;
        _config = updated;
        _error = null;
        if (!enabled) _cancelRefresh();
        _updateTimer();
      } on Exception catch (error) {
        _error = 'Could not save live Droneguide access. ${_message(error)}';
      }
      _changed();
    });
    if (enabled && autoRefresh && _foreground) await refresh();
  }

  void setForeground(bool value) {
    _foreground = value;
    if (_disposed) return;
    _updateTimer();
    if (value) {
      _tick();
    }
  }

  Future<void> importBytes(List<int> bytes, {required String filename}) async {
    await initialize();
    if (_disposed || _importing) return;
    _importing = true;
    _error = null;
    _changed();
    try {
      if (bytes.length > droneguideMaxBytes) {
        throw const FormatException('The file is larger than 12 MiB.');
      }
      final raw = utf8.decode(bytes);
      final data = await _datasetFromRaw(
        raw,
        fetchedAt: _now().toUtc(),
        filename: filename,
      );
      await _serialized(() async {
        if (_disposed) return;
        final updated = _config.withChanges(autoRefresh: false, imported: data);
        await _persist(updated);
        if (_disposed) return;
        _cancelRefresh();
        _config = updated;
        _error = null;
        _updateTimer();
      });
    } on Exception catch (error) {
      _error = 'Could not import the Droneguide file. ${_message(error)}';
    } finally {
      _importing = false;
      _changed();
    }
  }

  Future<void> refresh() async {
    await initialize();
    if (_disposed || !autoRefresh || _request != null) return;
    final abort = Completer<void>();
    _request = abort;
    final start = DateTime.fromMillisecondsSinceEpoch(
      _now().millisecondsSinceEpoch,
      isUtc: true,
    );
    _lastAttempt = start;
    _error = null;
    _changed();
    final deadline = Timer(const Duration(seconds: 45), () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final raw = await _fetch(start, abort.future);
      final data = await _datasetFromRaw(
        raw,
        fetchedAt: _now().toUtc(),
        snapshotAt: start,
      );
      await _serialized(() async {
        if (_disposed || _request != abort || !autoRefresh) return;
        final updated = _config.withChanges(live: data);
        await _persist(updated);
        if (_disposed || _request != abort) return;
        _config = updated;
        _failedRefresh = false;
        _error = null;
      });
    } on Exception catch (error) {
      if (_request == abort) {
        _failedRefresh = true;
        _error = 'Could not refresh Droneguide. ${_message(error)}';
      }
    } finally {
      deadline.cancel();
      if (!abort.isCompleted) abort.complete();
      if (_request == abort) {
        _request = null;
        _updateTimer();
        _changed();
      }
    }
  }

  void _cancelRefresh() {
    final prior = _request;
    _request = null;
    if (prior != null && !prior.isCompleted) prior.complete();
  }

  Future<String> _fetch(DateTime start, Future<void> abort) async {
    final features = <Object?>[];
    Object? crs;
    int? total;
    var remaining = droneguideMaxBytes;
    final client = _client ??= http.Client();
    for (var page = 0; page < _wfsMaxPages; page++) {
      final address = _wfsUrl(start, features.length);
      final request = http.AbortableRequest('GET', address, abortTrigger: abort)
        ..followRedirects = false
        ..headers['Accept'] = 'application/json';
      final response = await client.send(request);
      if (response.statusCode != 200) {
        // Drain is unnecessary since the shared abort closes the request.
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        throw FormatException(
            'Droneguide returned HTTP ${response.statusCode}.');
      }
      if ((response.contentLength ?? 0) > remaining || remaining <= 0) {
        final subscription = response.stream.listen(null);
        await subscription.cancel();
        throw const FormatException(
            'The online dataset is larger than 12 MiB.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.stream) {
        remaining -= part.length;
        if (remaining < 0) {
          throw const FormatException(
              'The online dataset is larger than 12 MiB.');
        }
        bytes.add(part);
      }
      final payload = await compute(_decodePage, bytes.takeBytes());
      total ??= payload.total;
      if (total != payload.total ||
          features.length + payload.features.length > total) {
        throw const FormatException(
            'The Droneguide dataset changed during refresh.');
      }
      if (page == 0) crs = payload.crs;
      features.addAll(payload.features);
      if (features.length == total) {
        final result = jsonEncode({
          'type': 'FeatureCollection',
          'features': features,
          if (crs != null) 'crs': crs,
        });
        if (utf8.encode(result).length > droneguideMaxBytes) {
          throw const FormatException(
              'The online dataset is larger than 12 MiB.');
        }
        return result;
      }
    }
    throw const FormatException('The online dataset is incomplete.');
  }

  Uri _wfsUrl(DateTime start, int offset) {
    String windowTime(DateTime time) =>
        time.toIso8601String().replaceAll(':', r'\:');
    return _endpoint.replace(queryParameters: {
      ..._endpoint.queryParameters,
      'service': 'WFS',
      'version': '2.0.0',
      'request': 'GetFeature',
      'typeNames': 'uaszone',
      'srsName': 'EPSG:4326',
      'outputFormat': 'application/json',
      'cql_filter': _wfsAltitudeFilter,
      'viewParams': 'window_start:${windowTime(start)};'
          'window_end:${windowTime(start.add(_wfsWindow))};show_planned:true',
      'count': '$_wfsPageSize',
      'startIndex': '$offset',
      'sortBy': 'unique_identifier A',
    });
  }

  void _updateTimer() {
    final needed =
        !_disposed && _foreground && (autoRefresh || snapshot != null);
    if (needed) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _tick() {
    final now = _now();
    final current = snapshot;
    final stale = _isStale(current, now);
    final statuses = _displayActivities(current, now, stale);
    if (_wasStale != stale || !listEquals(_lastActivities, statuses)) {
      _wasStale = stale;
      _lastActivities = statuses;
      notifyListeners();
    }
    final previous = _lastAttempt;
    if (_foreground &&
        autoRefresh &&
        _request == null &&
        (previous == null ||
            now.difference(previous) >= droneguideRefreshInterval)) {
      unawaited(refresh());
    }
  }

  List<bool?> _displayActivities(
          DroneguideSnapshot? current, DateTime now, bool stale) =>
      layerEnabled && current != null
          ? [
              for (final zone in current.zones)
                _activityAt(zone, current, now, stale)
            ]
          : const [];

  void _changed() {
    if (_disposed) return;
    final now = _now();
    final current = snapshot;
    _wasStale = _isStale(current, now);
    _lastActivities = _displayActivities(current, now, _wasStale);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _cancelRefresh();
    if (_ownsClient) _client?.close();
    super.dispose();
  }
}

String _message(Exception error) =>
    error is FormatException ? error.message.toString() : error.toString();

({int total, List<Object?> features, Object? crs}) _decodePage(
    Uint8List bytes) {
  final page = _object(_decode(utf8.decode(bytes)));
  if (page['type'] != 'FeatureCollection') {
    throw const FormatException('Droneguide did not return WFS features.');
  }
  _checkCrs(page);
  final matched = page['numberMatched'];
  final namedTotal = page['totalFeatures'];
  if (matched is int && namedTotal is int && matched != namedTotal) {
    throw const FormatException('Droneguide reported inconsistent WFS totals.');
  }
  final total = matched is int ? matched : namedTotal;
  if (total is! int || total <= 0 || total > _maxFeatures) {
    throw const FormatException(
        'Could not verify the total number of Droneguide zones.');
  }
  final features = _array(page['features']);
  final returned = page['numberReturned'];
  if (features.isEmpty || returned is! int || returned != features.length) {
    throw const FormatException('Droneguide returned an incomplete WFS page.');
  }
  return (total: total, features: features, crs: page['crs']);
}

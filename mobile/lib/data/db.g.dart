// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'db.dart';

// ignore_for_file: type=lint
class $DetectorsTable extends Detectors
    with TableInfo<$DetectorsTable, DetectorEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DetectorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _boardMeta = const VerificationMeta('board');
  @override
  late final GeneratedColumn<String> board = GeneratedColumn<String>(
      'board', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('unknown'));
  static const VerificationMeta _fwMeta = const VerificationMeta('fw');
  @override
  late final GeneratedColumn<String> fw = GeneratedColumn<String>(
      'fw', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('orecchino'));
  static const VerificationMeta _verMeta = const VerificationMeta('ver');
  @override
  late final GeneratedColumn<String> ver = GeneratedColumn<String>(
      'ver', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _capsMeta = const VerificationMeta('caps');
  @override
  late final GeneratedColumn<String> caps = GeneratedColumn<String>(
      'caps', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _lastSeenMeta =
      const VerificationMeta('lastSeen');
  @override
  late final GeneratedColumn<int> lastSeen = GeneratedColumn<int>(
      'last_seen', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastSyncSeqMeta =
      const VerificationMeta('lastSyncSeq');
  @override
  late final GeneratedColumn<int> lastSyncSeq = GeneratedColumn<int>(
      'last_sync_seq', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _oldestSeqMeta =
      const VerificationMeta('oldestSeq');
  @override
  late final GeneratedColumn<int> oldestSeq = GeneratedColumn<int>(
      'oldest_seq', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _bondedMeta = const VerificationMeta('bonded');
  @override
  late final GeneratedColumn<bool> bonded = GeneratedColumn<bool>(
      'bonded', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("bonded" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _lastSyncUtcMeta =
      const VerificationMeta('lastSyncUtc');
  @override
  late final GeneratedColumn<int> lastSyncUtc = GeneratedColumn<int>(
      'last_sync_utc', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _historyGapMeta =
      const VerificationMeta('historyGap');
  @override
  late final GeneratedColumn<bool> historyGap = GeneratedColumn<bool>(
      'history_gap', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("history_gap" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _logEpochMeta =
      const VerificationMeta('logEpoch');
  @override
  late final GeneratedColumn<int> logEpoch = GeneratedColumn<int>(
      'log_epoch', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _logIdMeta = const VerificationMeta('logId');
  @override
  late final GeneratedColumn<int> logId = GeneratedColumn<int>(
      'log_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        name,
        board,
        fw,
        ver,
        caps,
        lastSeen,
        lastSyncSeq,
        oldestSeq,
        bonded,
        lastSyncUtc,
        historyGap,
        logEpoch,
        logId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'detectors';
  @override
  VerificationContext validateIntegrity(Insertable<DetectorEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('board')) {
      context.handle(
          _boardMeta, board.isAcceptableOrUnknown(data['board']!, _boardMeta));
    }
    if (data.containsKey('fw')) {
      context.handle(_fwMeta, fw.isAcceptableOrUnknown(data['fw']!, _fwMeta));
    }
    if (data.containsKey('ver')) {
      context.handle(
          _verMeta, ver.isAcceptableOrUnknown(data['ver']!, _verMeta));
    }
    if (data.containsKey('caps')) {
      context.handle(
          _capsMeta, caps.isAcceptableOrUnknown(data['caps']!, _capsMeta));
    }
    if (data.containsKey('last_seen')) {
      context.handle(_lastSeenMeta,
          lastSeen.isAcceptableOrUnknown(data['last_seen']!, _lastSeenMeta));
    }
    if (data.containsKey('last_sync_seq')) {
      context.handle(
          _lastSyncSeqMeta,
          lastSyncSeq.isAcceptableOrUnknown(
              data['last_sync_seq']!, _lastSyncSeqMeta));
    }
    if (data.containsKey('oldest_seq')) {
      context.handle(_oldestSeqMeta,
          oldestSeq.isAcceptableOrUnknown(data['oldest_seq']!, _oldestSeqMeta));
    }
    if (data.containsKey('bonded')) {
      context.handle(_bondedMeta,
          bonded.isAcceptableOrUnknown(data['bonded']!, _bondedMeta));
    }
    if (data.containsKey('last_sync_utc')) {
      context.handle(
          _lastSyncUtcMeta,
          lastSyncUtc.isAcceptableOrUnknown(
              data['last_sync_utc']!, _lastSyncUtcMeta));
    }
    if (data.containsKey('history_gap')) {
      context.handle(
          _historyGapMeta,
          historyGap.isAcceptableOrUnknown(
              data['history_gap']!, _historyGapMeta));
    }
    if (data.containsKey('log_epoch')) {
      context.handle(_logEpochMeta,
          logEpoch.isAcceptableOrUnknown(data['log_epoch']!, _logEpochMeta));
    }
    if (data.containsKey('log_id')) {
      context.handle(
          _logIdMeta, logId.isAcceptableOrUnknown(data['log_id']!, _logIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DetectorEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DetectorEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      board: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}board'])!,
      fw: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}fw'])!,
      ver: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}ver'])!,
      caps: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}caps'])!,
      lastSeen: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_seen'])!,
      lastSyncSeq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_sync_seq'])!,
      oldestSeq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}oldest_seq']),
      bonded: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}bonded'])!,
      lastSyncUtc: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_sync_utc']),
      historyGap: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}history_gap'])!,
      logEpoch: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}log_epoch'])!,
      logId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}log_id']),
    );
  }

  @override
  $DetectorsTable createAlias(String alias) {
    return $DetectorsTable(attachedDatabase, alias);
  }
}

class DetectorEntry extends DataClass implements Insertable<DetectorEntry> {
  final String id;
  final String name;
  final String board;
  final String fw;
  final String ver;
  final String caps;
  final int lastSeen;
  final int lastSyncSeq;
  final int? oldestSeq;
  final bool bonded;
  final int? lastSyncUtc;
  final bool historyGap;
  final int logEpoch;

  /// The board's log identity the cursor belongs to (log_done `log_id`);
  /// null until the firmware sent one.
  final int? logId;
  const DetectorEntry(
      {required this.id,
      required this.name,
      required this.board,
      required this.fw,
      required this.ver,
      required this.caps,
      required this.lastSeen,
      required this.lastSyncSeq,
      this.oldestSeq,
      required this.bonded,
      this.lastSyncUtc,
      required this.historyGap,
      required this.logEpoch,
      this.logId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['board'] = Variable<String>(board);
    map['fw'] = Variable<String>(fw);
    map['ver'] = Variable<String>(ver);
    map['caps'] = Variable<String>(caps);
    map['last_seen'] = Variable<int>(lastSeen);
    map['last_sync_seq'] = Variable<int>(lastSyncSeq);
    if (!nullToAbsent || oldestSeq != null) {
      map['oldest_seq'] = Variable<int>(oldestSeq);
    }
    map['bonded'] = Variable<bool>(bonded);
    if (!nullToAbsent || lastSyncUtc != null) {
      map['last_sync_utc'] = Variable<int>(lastSyncUtc);
    }
    map['history_gap'] = Variable<bool>(historyGap);
    map['log_epoch'] = Variable<int>(logEpoch);
    if (!nullToAbsent || logId != null) {
      map['log_id'] = Variable<int>(logId);
    }
    return map;
  }

  DetectorsCompanion toCompanion(bool nullToAbsent) {
    return DetectorsCompanion(
      id: Value(id),
      name: Value(name),
      board: Value(board),
      fw: Value(fw),
      ver: Value(ver),
      caps: Value(caps),
      lastSeen: Value(lastSeen),
      lastSyncSeq: Value(lastSyncSeq),
      oldestSeq: oldestSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(oldestSeq),
      bonded: Value(bonded),
      lastSyncUtc: lastSyncUtc == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncUtc),
      historyGap: Value(historyGap),
      logEpoch: Value(logEpoch),
      logId:
          logId == null && nullToAbsent ? const Value.absent() : Value(logId),
    );
  }

  factory DetectorEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DetectorEntry(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      board: serializer.fromJson<String>(json['board']),
      fw: serializer.fromJson<String>(json['fw']),
      ver: serializer.fromJson<String>(json['ver']),
      caps: serializer.fromJson<String>(json['caps']),
      lastSeen: serializer.fromJson<int>(json['lastSeen']),
      lastSyncSeq: serializer.fromJson<int>(json['lastSyncSeq']),
      oldestSeq: serializer.fromJson<int?>(json['oldestSeq']),
      bonded: serializer.fromJson<bool>(json['bonded']),
      lastSyncUtc: serializer.fromJson<int?>(json['lastSyncUtc']),
      historyGap: serializer.fromJson<bool>(json['historyGap']),
      logEpoch: serializer.fromJson<int>(json['logEpoch']),
      logId: serializer.fromJson<int?>(json['logId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'board': serializer.toJson<String>(board),
      'fw': serializer.toJson<String>(fw),
      'ver': serializer.toJson<String>(ver),
      'caps': serializer.toJson<String>(caps),
      'lastSeen': serializer.toJson<int>(lastSeen),
      'lastSyncSeq': serializer.toJson<int>(lastSyncSeq),
      'oldestSeq': serializer.toJson<int?>(oldestSeq),
      'bonded': serializer.toJson<bool>(bonded),
      'lastSyncUtc': serializer.toJson<int?>(lastSyncUtc),
      'historyGap': serializer.toJson<bool>(historyGap),
      'logEpoch': serializer.toJson<int>(logEpoch),
      'logId': serializer.toJson<int?>(logId),
    };
  }

  DetectorEntry copyWith(
          {String? id,
          String? name,
          String? board,
          String? fw,
          String? ver,
          String? caps,
          int? lastSeen,
          int? lastSyncSeq,
          Value<int?> oldestSeq = const Value.absent(),
          bool? bonded,
          Value<int?> lastSyncUtc = const Value.absent(),
          bool? historyGap,
          int? logEpoch,
          Value<int?> logId = const Value.absent()}) =>
      DetectorEntry(
        id: id ?? this.id,
        name: name ?? this.name,
        board: board ?? this.board,
        fw: fw ?? this.fw,
        ver: ver ?? this.ver,
        caps: caps ?? this.caps,
        lastSeen: lastSeen ?? this.lastSeen,
        lastSyncSeq: lastSyncSeq ?? this.lastSyncSeq,
        oldestSeq: oldestSeq.present ? oldestSeq.value : this.oldestSeq,
        bonded: bonded ?? this.bonded,
        lastSyncUtc: lastSyncUtc.present ? lastSyncUtc.value : this.lastSyncUtc,
        historyGap: historyGap ?? this.historyGap,
        logEpoch: logEpoch ?? this.logEpoch,
        logId: logId.present ? logId.value : this.logId,
      );
  DetectorEntry copyWithCompanion(DetectorsCompanion data) {
    return DetectorEntry(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      board: data.board.present ? data.board.value : this.board,
      fw: data.fw.present ? data.fw.value : this.fw,
      ver: data.ver.present ? data.ver.value : this.ver,
      caps: data.caps.present ? data.caps.value : this.caps,
      lastSeen: data.lastSeen.present ? data.lastSeen.value : this.lastSeen,
      lastSyncSeq:
          data.lastSyncSeq.present ? data.lastSyncSeq.value : this.lastSyncSeq,
      oldestSeq: data.oldestSeq.present ? data.oldestSeq.value : this.oldestSeq,
      bonded: data.bonded.present ? data.bonded.value : this.bonded,
      lastSyncUtc:
          data.lastSyncUtc.present ? data.lastSyncUtc.value : this.lastSyncUtc,
      historyGap:
          data.historyGap.present ? data.historyGap.value : this.historyGap,
      logEpoch: data.logEpoch.present ? data.logEpoch.value : this.logEpoch,
      logId: data.logId.present ? data.logId.value : this.logId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DetectorEntry(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('board: $board, ')
          ..write('fw: $fw, ')
          ..write('ver: $ver, ')
          ..write('caps: $caps, ')
          ..write('lastSeen: $lastSeen, ')
          ..write('lastSyncSeq: $lastSyncSeq, ')
          ..write('oldestSeq: $oldestSeq, ')
          ..write('bonded: $bonded, ')
          ..write('lastSyncUtc: $lastSyncUtc, ')
          ..write('historyGap: $historyGap, ')
          ..write('logEpoch: $logEpoch, ')
          ..write('logId: $logId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, board, fw, ver, caps, lastSeen,
      lastSyncSeq, oldestSeq, bonded, lastSyncUtc, historyGap, logEpoch, logId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DetectorEntry &&
          other.id == this.id &&
          other.name == this.name &&
          other.board == this.board &&
          other.fw == this.fw &&
          other.ver == this.ver &&
          other.caps == this.caps &&
          other.lastSeen == this.lastSeen &&
          other.lastSyncSeq == this.lastSyncSeq &&
          other.oldestSeq == this.oldestSeq &&
          other.bonded == this.bonded &&
          other.lastSyncUtc == this.lastSyncUtc &&
          other.historyGap == this.historyGap &&
          other.logEpoch == this.logEpoch &&
          other.logId == this.logId);
}

class DetectorsCompanion extends UpdateCompanion<DetectorEntry> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> board;
  final Value<String> fw;
  final Value<String> ver;
  final Value<String> caps;
  final Value<int> lastSeen;
  final Value<int> lastSyncSeq;
  final Value<int?> oldestSeq;
  final Value<bool> bonded;
  final Value<int?> lastSyncUtc;
  final Value<bool> historyGap;
  final Value<int> logEpoch;
  final Value<int?> logId;
  final Value<int> rowid;
  const DetectorsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.board = const Value.absent(),
    this.fw = const Value.absent(),
    this.ver = const Value.absent(),
    this.caps = const Value.absent(),
    this.lastSeen = const Value.absent(),
    this.lastSyncSeq = const Value.absent(),
    this.oldestSeq = const Value.absent(),
    this.bonded = const Value.absent(),
    this.lastSyncUtc = const Value.absent(),
    this.historyGap = const Value.absent(),
    this.logEpoch = const Value.absent(),
    this.logId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DetectorsCompanion.insert({
    required String id,
    required String name,
    this.board = const Value.absent(),
    this.fw = const Value.absent(),
    this.ver = const Value.absent(),
    this.caps = const Value.absent(),
    this.lastSeen = const Value.absent(),
    this.lastSyncSeq = const Value.absent(),
    this.oldestSeq = const Value.absent(),
    this.bonded = const Value.absent(),
    this.lastSyncUtc = const Value.absent(),
    this.historyGap = const Value.absent(),
    this.logEpoch = const Value.absent(),
    this.logId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        name = Value(name);
  static Insertable<DetectorEntry> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? board,
    Expression<String>? fw,
    Expression<String>? ver,
    Expression<String>? caps,
    Expression<int>? lastSeen,
    Expression<int>? lastSyncSeq,
    Expression<int>? oldestSeq,
    Expression<bool>? bonded,
    Expression<int>? lastSyncUtc,
    Expression<bool>? historyGap,
    Expression<int>? logEpoch,
    Expression<int>? logId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (board != null) 'board': board,
      if (fw != null) 'fw': fw,
      if (ver != null) 'ver': ver,
      if (caps != null) 'caps': caps,
      if (lastSeen != null) 'last_seen': lastSeen,
      if (lastSyncSeq != null) 'last_sync_seq': lastSyncSeq,
      if (oldestSeq != null) 'oldest_seq': oldestSeq,
      if (bonded != null) 'bonded': bonded,
      if (lastSyncUtc != null) 'last_sync_utc': lastSyncUtc,
      if (historyGap != null) 'history_gap': historyGap,
      if (logEpoch != null) 'log_epoch': logEpoch,
      if (logId != null) 'log_id': logId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DetectorsCompanion copyWith(
      {Value<String>? id,
      Value<String>? name,
      Value<String>? board,
      Value<String>? fw,
      Value<String>? ver,
      Value<String>? caps,
      Value<int>? lastSeen,
      Value<int>? lastSyncSeq,
      Value<int?>? oldestSeq,
      Value<bool>? bonded,
      Value<int?>? lastSyncUtc,
      Value<bool>? historyGap,
      Value<int>? logEpoch,
      Value<int?>? logId,
      Value<int>? rowid}) {
    return DetectorsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      board: board ?? this.board,
      fw: fw ?? this.fw,
      ver: ver ?? this.ver,
      caps: caps ?? this.caps,
      lastSeen: lastSeen ?? this.lastSeen,
      lastSyncSeq: lastSyncSeq ?? this.lastSyncSeq,
      oldestSeq: oldestSeq ?? this.oldestSeq,
      bonded: bonded ?? this.bonded,
      lastSyncUtc: lastSyncUtc ?? this.lastSyncUtc,
      historyGap: historyGap ?? this.historyGap,
      logEpoch: logEpoch ?? this.logEpoch,
      logId: logId ?? this.logId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (board.present) {
      map['board'] = Variable<String>(board.value);
    }
    if (fw.present) {
      map['fw'] = Variable<String>(fw.value);
    }
    if (ver.present) {
      map['ver'] = Variable<String>(ver.value);
    }
    if (caps.present) {
      map['caps'] = Variable<String>(caps.value);
    }
    if (lastSeen.present) {
      map['last_seen'] = Variable<int>(lastSeen.value);
    }
    if (lastSyncSeq.present) {
      map['last_sync_seq'] = Variable<int>(lastSyncSeq.value);
    }
    if (oldestSeq.present) {
      map['oldest_seq'] = Variable<int>(oldestSeq.value);
    }
    if (bonded.present) {
      map['bonded'] = Variable<bool>(bonded.value);
    }
    if (lastSyncUtc.present) {
      map['last_sync_utc'] = Variable<int>(lastSyncUtc.value);
    }
    if (historyGap.present) {
      map['history_gap'] = Variable<bool>(historyGap.value);
    }
    if (logEpoch.present) {
      map['log_epoch'] = Variable<int>(logEpoch.value);
    }
    if (logId.present) {
      map['log_id'] = Variable<int>(logId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DetectorsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('board: $board, ')
          ..write('fw: $fw, ')
          ..write('ver: $ver, ')
          ..write('caps: $caps, ')
          ..write('lastSeen: $lastSeen, ')
          ..write('lastSyncSeq: $lastSyncSeq, ')
          ..write('oldestSeq: $oldestSeq, ')
          ..write('bonded: $bonded, ')
          ..write('lastSyncUtc: $lastSyncUtc, ')
          ..write('historyGap: $historyGap, ')
          ..write('logEpoch: $logEpoch, ')
          ..write('logId: $logId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DetectionsTable extends Detections
    with TableInfo<$DetectionsTable, DetectionEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DetectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _detectorIdMeta =
      const VerificationMeta('detectorId');
  @override
  late final GeneratedColumn<String> detectorId = GeneratedColumn<String>(
      'detector_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _rowKeyMeta = const VerificationMeta('rowKey');
  @override
  late final GeneratedColumn<String> rowKey = GeneratedColumn<String>(
      'row_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
      'seq', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _activeMeta = const VerificationMeta('active');
  @override
  late final GeneratedColumn<bool> active = GeneratedColumn<bool>(
      'active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("active" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _uasIdMeta = const VerificationMeta('uasId');
  @override
  late final GeneratedColumn<String> uasId = GeneratedColumn<String>(
      'uas_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _macMeta = const VerificationMeta('mac');
  @override
  late final GeneratedColumn<String> mac = GeneratedColumn<String>(
      'mac', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _srcsMeta = const VerificationMeta('srcs');
  @override
  late final GeneratedColumn<int> srcs = GeneratedColumn<int>(
      'srcs', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _fmtsMeta = const VerificationMeta('fmts');
  @override
  late final GeneratedColumn<int> fmts = GeneratedColumn<int>(
      'fmts', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _uaTypeMeta = const VerificationMeta('uaType');
  @override
  late final GeneratedColumn<int> uaType = GeneratedColumn<int>(
      'ua_type', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _firstUtcMeta =
      const VerificationMeta('firstUtc');
  @override
  late final GeneratedColumn<int> firstUtc = GeneratedColumn<int>(
      'first_utc', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _lastUtcMeta =
      const VerificationMeta('lastUtc');
  @override
  late final GeneratedColumn<int> lastUtc = GeneratedColumn<int>(
      'last_utc', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _durSMeta = const VerificationMeta('durS');
  @override
  late final GeneratedColumn<int> durS = GeneratedColumn<int>(
      'dur_s', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _latMeta = const VerificationMeta('lat');
  @override
  late final GeneratedColumn<double> lat = GeneratedColumn<double>(
      'lat', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _lonMeta = const VerificationMeta('lon');
  @override
  late final GeneratedColumn<double> lon = GeneratedColumn<double>(
      'lon', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _maxHMeta = const VerificationMeta('maxH');
  @override
  late final GeneratedColumn<double> maxH = GeneratedColumn<double>(
      'max_h', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _peakRssiMeta =
      const VerificationMeta('peakRssi');
  @override
  late final GeneratedColumn<int> peakRssi = GeneratedColumn<int>(
      'peak_rssi', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _authStateMeta =
      const VerificationMeta('authState');
  @override
  late final GeneratedColumn<String> authState = GeneratedColumn<String>(
      'auth_state', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('none'));
  static const VerificationMeta _tfrMeta = const VerificationMeta('tfr');
  @override
  late final GeneratedColumn<bool> tfr = GeneratedColumn<bool>(
      'tfr', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("tfr" IN (0, 1))'));
  static const VerificationMeta _inTfrMeta = const VerificationMeta('inTfr');
  @override
  late final GeneratedColumn<bool> inTfr = GeneratedColumn<bool>(
      'in_tfr', aliasedName, true,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("in_tfr" IN (0, 1))'));
  static const VerificationMeta _tfrIdMeta = const VerificationMeta('tfrId');
  @override
  late final GeneratedColumn<String> tfrId = GeneratedColumn<String>(
      'tfr_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _classTypeMeta =
      const VerificationMeta('classType');
  @override
  late final GeneratedColumn<int> classType = GeneratedColumn<int>(
      'class_type', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _catEuMeta = const VerificationMeta('catEu');
  @override
  late final GeneratedColumn<int> catEu = GeneratedColumn<int>(
      'cat_eu', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _classEuMeta =
      const VerificationMeta('classEu');
  @override
  late final GeneratedColumn<int> classEu = GeneratedColumn<int>(
      'class_eu', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _emergMeta = const VerificationMeta('emerg');
  @override
  late final GeneratedColumn<bool> emerg = GeneratedColumn<bool>(
      'emerg', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("emerg" IN (0, 1))'));
  static const VerificationMeta _msgsMeta = const VerificationMeta('msgs');
  @override
  late final GeneratedColumn<int> msgs = GeneratedColumn<int>(
      'msgs', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        detectorId,
        rowKey,
        seq,
        active,
        uasId,
        mac,
        srcs,
        fmts,
        uaType,
        firstUtc,
        lastUtc,
        durS,
        lat,
        lon,
        maxH,
        peakRssi,
        authState,
        tfr,
        inTfr,
        tfrId,
        classType,
        catEu,
        classEu,
        emerg,
        msgs
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'detections';
  @override
  VerificationContext validateIntegrity(Insertable<DetectionEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('detector_id')) {
      context.handle(
          _detectorIdMeta,
          detectorId.isAcceptableOrUnknown(
              data['detector_id']!, _detectorIdMeta));
    } else if (isInserting) {
      context.missing(_detectorIdMeta);
    }
    if (data.containsKey('row_key')) {
      context.handle(_rowKeyMeta,
          rowKey.isAcceptableOrUnknown(data['row_key']!, _rowKeyMeta));
    } else if (isInserting) {
      context.missing(_rowKeyMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
          _seqMeta, seq.isAcceptableOrUnknown(data['seq']!, _seqMeta));
    }
    if (data.containsKey('active')) {
      context.handle(_activeMeta,
          active.isAcceptableOrUnknown(data['active']!, _activeMeta));
    }
    if (data.containsKey('uas_id')) {
      context.handle(
          _uasIdMeta, uasId.isAcceptableOrUnknown(data['uas_id']!, _uasIdMeta));
    }
    if (data.containsKey('mac')) {
      context.handle(
          _macMeta, mac.isAcceptableOrUnknown(data['mac']!, _macMeta));
    } else if (isInserting) {
      context.missing(_macMeta);
    }
    if (data.containsKey('srcs')) {
      context.handle(
          _srcsMeta, srcs.isAcceptableOrUnknown(data['srcs']!, _srcsMeta));
    }
    if (data.containsKey('fmts')) {
      context.handle(
          _fmtsMeta, fmts.isAcceptableOrUnknown(data['fmts']!, _fmtsMeta));
    }
    if (data.containsKey('ua_type')) {
      context.handle(_uaTypeMeta,
          uaType.isAcceptableOrUnknown(data['ua_type']!, _uaTypeMeta));
    }
    if (data.containsKey('first_utc')) {
      context.handle(_firstUtcMeta,
          firstUtc.isAcceptableOrUnknown(data['first_utc']!, _firstUtcMeta));
    } else if (isInserting) {
      context.missing(_firstUtcMeta);
    }
    if (data.containsKey('last_utc')) {
      context.handle(_lastUtcMeta,
          lastUtc.isAcceptableOrUnknown(data['last_utc']!, _lastUtcMeta));
    } else if (isInserting) {
      context.missing(_lastUtcMeta);
    }
    if (data.containsKey('dur_s')) {
      context.handle(
          _durSMeta, durS.isAcceptableOrUnknown(data['dur_s']!, _durSMeta));
    } else if (isInserting) {
      context.missing(_durSMeta);
    }
    if (data.containsKey('lat')) {
      context.handle(
          _latMeta, lat.isAcceptableOrUnknown(data['lat']!, _latMeta));
    }
    if (data.containsKey('lon')) {
      context.handle(
          _lonMeta, lon.isAcceptableOrUnknown(data['lon']!, _lonMeta));
    }
    if (data.containsKey('max_h')) {
      context.handle(
          _maxHMeta, maxH.isAcceptableOrUnknown(data['max_h']!, _maxHMeta));
    }
    if (data.containsKey('peak_rssi')) {
      context.handle(_peakRssiMeta,
          peakRssi.isAcceptableOrUnknown(data['peak_rssi']!, _peakRssiMeta));
    }
    if (data.containsKey('auth_state')) {
      context.handle(_authStateMeta,
          authState.isAcceptableOrUnknown(data['auth_state']!, _authStateMeta));
    }
    if (data.containsKey('tfr')) {
      context.handle(
          _tfrMeta, tfr.isAcceptableOrUnknown(data['tfr']!, _tfrMeta));
    } else if (isInserting) {
      context.missing(_tfrMeta);
    }
    if (data.containsKey('in_tfr')) {
      context.handle(
          _inTfrMeta, inTfr.isAcceptableOrUnknown(data['in_tfr']!, _inTfrMeta));
    }
    if (data.containsKey('tfr_id')) {
      context.handle(
          _tfrIdMeta, tfrId.isAcceptableOrUnknown(data['tfr_id']!, _tfrIdMeta));
    }
    if (data.containsKey('class_type')) {
      context.handle(_classTypeMeta,
          classType.isAcceptableOrUnknown(data['class_type']!, _classTypeMeta));
    }
    if (data.containsKey('cat_eu')) {
      context.handle(
          _catEuMeta, catEu.isAcceptableOrUnknown(data['cat_eu']!, _catEuMeta));
    }
    if (data.containsKey('class_eu')) {
      context.handle(_classEuMeta,
          classEu.isAcceptableOrUnknown(data['class_eu']!, _classEuMeta));
    }
    if (data.containsKey('emerg')) {
      context.handle(
          _emergMeta, emerg.isAcceptableOrUnknown(data['emerg']!, _emergMeta));
    } else if (isInserting) {
      context.missing(_emergMeta);
    }
    if (data.containsKey('msgs')) {
      context.handle(
          _msgsMeta, msgs.isAcceptableOrUnknown(data['msgs']!, _msgsMeta));
    } else if (isInserting) {
      context.missing(_msgsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {detectorId, rowKey};
  @override
  DetectionEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DetectionEntry(
      detectorId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}detector_id'])!,
      rowKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}row_key'])!,
      seq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}seq']),
      active: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}active'])!,
      uasId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uas_id']),
      mac: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}mac'])!,
      srcs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}srcs']),
      fmts: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}fmts']),
      uaType: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ua_type']),
      firstUtc: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}first_utc'])!,
      lastUtc: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_utc'])!,
      durS: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}dur_s'])!,
      lat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lat']),
      lon: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lon']),
      maxH: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}max_h']),
      peakRssi: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}peak_rssi']),
      authState: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}auth_state'])!,
      tfr: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}tfr'])!,
      inTfr: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}in_tfr']),
      tfrId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tfr_id']),
      classType: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}class_type']),
      catEu: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}cat_eu']),
      classEu: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}class_eu']),
      emerg: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}emerg'])!,
      msgs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}msgs'])!,
    );
  }

  @override
  $DetectionsTable createAlias(String alias) {
    return $DetectionsTable(attachedDatabase, alias);
  }
}

class DetectionEntry extends DataClass implements Insertable<DetectionEntry> {
  final String detectorId;
  final String rowKey;
  final int? seq;
  final bool active;
  final String? uasId;
  final String mac;
  final int? srcs;
  final int? fmts;
  final int? uaType;
  final int firstUtc;
  final int lastUtc;
  final int durS;
  final double? lat;
  final double? lon;
  final double? maxH;
  final int? peakRssi;
  final String authState;
  final bool tfr;
  final bool? inTfr;
  final String? tfrId;
  final int? classType;
  final int? catEu;
  final int? classEu;
  final bool emerg;
  final int msgs;
  const DetectionEntry(
      {required this.detectorId,
      required this.rowKey,
      this.seq,
      required this.active,
      this.uasId,
      required this.mac,
      this.srcs,
      this.fmts,
      this.uaType,
      required this.firstUtc,
      required this.lastUtc,
      required this.durS,
      this.lat,
      this.lon,
      this.maxH,
      this.peakRssi,
      required this.authState,
      required this.tfr,
      this.inTfr,
      this.tfrId,
      this.classType,
      this.catEu,
      this.classEu,
      required this.emerg,
      required this.msgs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['detector_id'] = Variable<String>(detectorId);
    map['row_key'] = Variable<String>(rowKey);
    if (!nullToAbsent || seq != null) {
      map['seq'] = Variable<int>(seq);
    }
    map['active'] = Variable<bool>(active);
    if (!nullToAbsent || uasId != null) {
      map['uas_id'] = Variable<String>(uasId);
    }
    map['mac'] = Variable<String>(mac);
    if (!nullToAbsent || srcs != null) {
      map['srcs'] = Variable<int>(srcs);
    }
    if (!nullToAbsent || fmts != null) {
      map['fmts'] = Variable<int>(fmts);
    }
    if (!nullToAbsent || uaType != null) {
      map['ua_type'] = Variable<int>(uaType);
    }
    map['first_utc'] = Variable<int>(firstUtc);
    map['last_utc'] = Variable<int>(lastUtc);
    map['dur_s'] = Variable<int>(durS);
    if (!nullToAbsent || lat != null) {
      map['lat'] = Variable<double>(lat);
    }
    if (!nullToAbsent || lon != null) {
      map['lon'] = Variable<double>(lon);
    }
    if (!nullToAbsent || maxH != null) {
      map['max_h'] = Variable<double>(maxH);
    }
    if (!nullToAbsent || peakRssi != null) {
      map['peak_rssi'] = Variable<int>(peakRssi);
    }
    map['auth_state'] = Variable<String>(authState);
    map['tfr'] = Variable<bool>(tfr);
    if (!nullToAbsent || inTfr != null) {
      map['in_tfr'] = Variable<bool>(inTfr);
    }
    if (!nullToAbsent || tfrId != null) {
      map['tfr_id'] = Variable<String>(tfrId);
    }
    if (!nullToAbsent || classType != null) {
      map['class_type'] = Variable<int>(classType);
    }
    if (!nullToAbsent || catEu != null) {
      map['cat_eu'] = Variable<int>(catEu);
    }
    if (!nullToAbsent || classEu != null) {
      map['class_eu'] = Variable<int>(classEu);
    }
    map['emerg'] = Variable<bool>(emerg);
    map['msgs'] = Variable<int>(msgs);
    return map;
  }

  DetectionsCompanion toCompanion(bool nullToAbsent) {
    return DetectionsCompanion(
      detectorId: Value(detectorId),
      rowKey: Value(rowKey),
      seq: seq == null && nullToAbsent ? const Value.absent() : Value(seq),
      active: Value(active),
      uasId:
          uasId == null && nullToAbsent ? const Value.absent() : Value(uasId),
      mac: Value(mac),
      srcs: srcs == null && nullToAbsent ? const Value.absent() : Value(srcs),
      fmts: fmts == null && nullToAbsent ? const Value.absent() : Value(fmts),
      uaType:
          uaType == null && nullToAbsent ? const Value.absent() : Value(uaType),
      firstUtc: Value(firstUtc),
      lastUtc: Value(lastUtc),
      durS: Value(durS),
      lat: lat == null && nullToAbsent ? const Value.absent() : Value(lat),
      lon: lon == null && nullToAbsent ? const Value.absent() : Value(lon),
      maxH: maxH == null && nullToAbsent ? const Value.absent() : Value(maxH),
      peakRssi: peakRssi == null && nullToAbsent
          ? const Value.absent()
          : Value(peakRssi),
      authState: Value(authState),
      tfr: Value(tfr),
      inTfr:
          inTfr == null && nullToAbsent ? const Value.absent() : Value(inTfr),
      tfrId:
          tfrId == null && nullToAbsent ? const Value.absent() : Value(tfrId),
      classType: classType == null && nullToAbsent
          ? const Value.absent()
          : Value(classType),
      catEu:
          catEu == null && nullToAbsent ? const Value.absent() : Value(catEu),
      classEu: classEu == null && nullToAbsent
          ? const Value.absent()
          : Value(classEu),
      emerg: Value(emerg),
      msgs: Value(msgs),
    );
  }

  factory DetectionEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DetectionEntry(
      detectorId: serializer.fromJson<String>(json['detectorId']),
      rowKey: serializer.fromJson<String>(json['rowKey']),
      seq: serializer.fromJson<int?>(json['seq']),
      active: serializer.fromJson<bool>(json['active']),
      uasId: serializer.fromJson<String?>(json['uasId']),
      mac: serializer.fromJson<String>(json['mac']),
      srcs: serializer.fromJson<int?>(json['srcs']),
      fmts: serializer.fromJson<int?>(json['fmts']),
      uaType: serializer.fromJson<int?>(json['uaType']),
      firstUtc: serializer.fromJson<int>(json['firstUtc']),
      lastUtc: serializer.fromJson<int>(json['lastUtc']),
      durS: serializer.fromJson<int>(json['durS']),
      lat: serializer.fromJson<double?>(json['lat']),
      lon: serializer.fromJson<double?>(json['lon']),
      maxH: serializer.fromJson<double?>(json['maxH']),
      peakRssi: serializer.fromJson<int?>(json['peakRssi']),
      authState: serializer.fromJson<String>(json['authState']),
      tfr: serializer.fromJson<bool>(json['tfr']),
      inTfr: serializer.fromJson<bool?>(json['inTfr']),
      tfrId: serializer.fromJson<String?>(json['tfrId']),
      classType: serializer.fromJson<int?>(json['classType']),
      catEu: serializer.fromJson<int?>(json['catEu']),
      classEu: serializer.fromJson<int?>(json['classEu']),
      emerg: serializer.fromJson<bool>(json['emerg']),
      msgs: serializer.fromJson<int>(json['msgs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'detectorId': serializer.toJson<String>(detectorId),
      'rowKey': serializer.toJson<String>(rowKey),
      'seq': serializer.toJson<int?>(seq),
      'active': serializer.toJson<bool>(active),
      'uasId': serializer.toJson<String?>(uasId),
      'mac': serializer.toJson<String>(mac),
      'srcs': serializer.toJson<int?>(srcs),
      'fmts': serializer.toJson<int?>(fmts),
      'uaType': serializer.toJson<int?>(uaType),
      'firstUtc': serializer.toJson<int>(firstUtc),
      'lastUtc': serializer.toJson<int>(lastUtc),
      'durS': serializer.toJson<int>(durS),
      'lat': serializer.toJson<double?>(lat),
      'lon': serializer.toJson<double?>(lon),
      'maxH': serializer.toJson<double?>(maxH),
      'peakRssi': serializer.toJson<int?>(peakRssi),
      'authState': serializer.toJson<String>(authState),
      'tfr': serializer.toJson<bool>(tfr),
      'inTfr': serializer.toJson<bool?>(inTfr),
      'tfrId': serializer.toJson<String?>(tfrId),
      'classType': serializer.toJson<int?>(classType),
      'catEu': serializer.toJson<int?>(catEu),
      'classEu': serializer.toJson<int?>(classEu),
      'emerg': serializer.toJson<bool>(emerg),
      'msgs': serializer.toJson<int>(msgs),
    };
  }

  DetectionEntry copyWith(
          {String? detectorId,
          String? rowKey,
          Value<int?> seq = const Value.absent(),
          bool? active,
          Value<String?> uasId = const Value.absent(),
          String? mac,
          Value<int?> srcs = const Value.absent(),
          Value<int?> fmts = const Value.absent(),
          Value<int?> uaType = const Value.absent(),
          int? firstUtc,
          int? lastUtc,
          int? durS,
          Value<double?> lat = const Value.absent(),
          Value<double?> lon = const Value.absent(),
          Value<double?> maxH = const Value.absent(),
          Value<int?> peakRssi = const Value.absent(),
          String? authState,
          bool? tfr,
          Value<bool?> inTfr = const Value.absent(),
          Value<String?> tfrId = const Value.absent(),
          Value<int?> classType = const Value.absent(),
          Value<int?> catEu = const Value.absent(),
          Value<int?> classEu = const Value.absent(),
          bool? emerg,
          int? msgs}) =>
      DetectionEntry(
        detectorId: detectorId ?? this.detectorId,
        rowKey: rowKey ?? this.rowKey,
        seq: seq.present ? seq.value : this.seq,
        active: active ?? this.active,
        uasId: uasId.present ? uasId.value : this.uasId,
        mac: mac ?? this.mac,
        srcs: srcs.present ? srcs.value : this.srcs,
        fmts: fmts.present ? fmts.value : this.fmts,
        uaType: uaType.present ? uaType.value : this.uaType,
        firstUtc: firstUtc ?? this.firstUtc,
        lastUtc: lastUtc ?? this.lastUtc,
        durS: durS ?? this.durS,
        lat: lat.present ? lat.value : this.lat,
        lon: lon.present ? lon.value : this.lon,
        maxH: maxH.present ? maxH.value : this.maxH,
        peakRssi: peakRssi.present ? peakRssi.value : this.peakRssi,
        authState: authState ?? this.authState,
        tfr: tfr ?? this.tfr,
        inTfr: inTfr.present ? inTfr.value : this.inTfr,
        tfrId: tfrId.present ? tfrId.value : this.tfrId,
        classType: classType.present ? classType.value : this.classType,
        catEu: catEu.present ? catEu.value : this.catEu,
        classEu: classEu.present ? classEu.value : this.classEu,
        emerg: emerg ?? this.emerg,
        msgs: msgs ?? this.msgs,
      );
  DetectionEntry copyWithCompanion(DetectionsCompanion data) {
    return DetectionEntry(
      detectorId:
          data.detectorId.present ? data.detectorId.value : this.detectorId,
      rowKey: data.rowKey.present ? data.rowKey.value : this.rowKey,
      seq: data.seq.present ? data.seq.value : this.seq,
      active: data.active.present ? data.active.value : this.active,
      uasId: data.uasId.present ? data.uasId.value : this.uasId,
      mac: data.mac.present ? data.mac.value : this.mac,
      srcs: data.srcs.present ? data.srcs.value : this.srcs,
      fmts: data.fmts.present ? data.fmts.value : this.fmts,
      uaType: data.uaType.present ? data.uaType.value : this.uaType,
      firstUtc: data.firstUtc.present ? data.firstUtc.value : this.firstUtc,
      lastUtc: data.lastUtc.present ? data.lastUtc.value : this.lastUtc,
      durS: data.durS.present ? data.durS.value : this.durS,
      lat: data.lat.present ? data.lat.value : this.lat,
      lon: data.lon.present ? data.lon.value : this.lon,
      maxH: data.maxH.present ? data.maxH.value : this.maxH,
      peakRssi: data.peakRssi.present ? data.peakRssi.value : this.peakRssi,
      authState: data.authState.present ? data.authState.value : this.authState,
      tfr: data.tfr.present ? data.tfr.value : this.tfr,
      inTfr: data.inTfr.present ? data.inTfr.value : this.inTfr,
      tfrId: data.tfrId.present ? data.tfrId.value : this.tfrId,
      classType: data.classType.present ? data.classType.value : this.classType,
      catEu: data.catEu.present ? data.catEu.value : this.catEu,
      classEu: data.classEu.present ? data.classEu.value : this.classEu,
      emerg: data.emerg.present ? data.emerg.value : this.emerg,
      msgs: data.msgs.present ? data.msgs.value : this.msgs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DetectionEntry(')
          ..write('detectorId: $detectorId, ')
          ..write('rowKey: $rowKey, ')
          ..write('seq: $seq, ')
          ..write('active: $active, ')
          ..write('uasId: $uasId, ')
          ..write('mac: $mac, ')
          ..write('srcs: $srcs, ')
          ..write('fmts: $fmts, ')
          ..write('uaType: $uaType, ')
          ..write('firstUtc: $firstUtc, ')
          ..write('lastUtc: $lastUtc, ')
          ..write('durS: $durS, ')
          ..write('lat: $lat, ')
          ..write('lon: $lon, ')
          ..write('maxH: $maxH, ')
          ..write('peakRssi: $peakRssi, ')
          ..write('authState: $authState, ')
          ..write('tfr: $tfr, ')
          ..write('inTfr: $inTfr, ')
          ..write('tfrId: $tfrId, ')
          ..write('classType: $classType, ')
          ..write('catEu: $catEu, ')
          ..write('classEu: $classEu, ')
          ..write('emerg: $emerg, ')
          ..write('msgs: $msgs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        detectorId,
        rowKey,
        seq,
        active,
        uasId,
        mac,
        srcs,
        fmts,
        uaType,
        firstUtc,
        lastUtc,
        durS,
        lat,
        lon,
        maxH,
        peakRssi,
        authState,
        tfr,
        inTfr,
        tfrId,
        classType,
        catEu,
        classEu,
        emerg,
        msgs
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DetectionEntry &&
          other.detectorId == this.detectorId &&
          other.rowKey == this.rowKey &&
          other.seq == this.seq &&
          other.active == this.active &&
          other.uasId == this.uasId &&
          other.mac == this.mac &&
          other.srcs == this.srcs &&
          other.fmts == this.fmts &&
          other.uaType == this.uaType &&
          other.firstUtc == this.firstUtc &&
          other.lastUtc == this.lastUtc &&
          other.durS == this.durS &&
          other.lat == this.lat &&
          other.lon == this.lon &&
          other.maxH == this.maxH &&
          other.peakRssi == this.peakRssi &&
          other.authState == this.authState &&
          other.tfr == this.tfr &&
          other.inTfr == this.inTfr &&
          other.tfrId == this.tfrId &&
          other.classType == this.classType &&
          other.catEu == this.catEu &&
          other.classEu == this.classEu &&
          other.emerg == this.emerg &&
          other.msgs == this.msgs);
}

class DetectionsCompanion extends UpdateCompanion<DetectionEntry> {
  final Value<String> detectorId;
  final Value<String> rowKey;
  final Value<int?> seq;
  final Value<bool> active;
  final Value<String?> uasId;
  final Value<String> mac;
  final Value<int?> srcs;
  final Value<int?> fmts;
  final Value<int?> uaType;
  final Value<int> firstUtc;
  final Value<int> lastUtc;
  final Value<int> durS;
  final Value<double?> lat;
  final Value<double?> lon;
  final Value<double?> maxH;
  final Value<int?> peakRssi;
  final Value<String> authState;
  final Value<bool> tfr;
  final Value<bool?> inTfr;
  final Value<String?> tfrId;
  final Value<int?> classType;
  final Value<int?> catEu;
  final Value<int?> classEu;
  final Value<bool> emerg;
  final Value<int> msgs;
  final Value<int> rowid;
  const DetectionsCompanion({
    this.detectorId = const Value.absent(),
    this.rowKey = const Value.absent(),
    this.seq = const Value.absent(),
    this.active = const Value.absent(),
    this.uasId = const Value.absent(),
    this.mac = const Value.absent(),
    this.srcs = const Value.absent(),
    this.fmts = const Value.absent(),
    this.uaType = const Value.absent(),
    this.firstUtc = const Value.absent(),
    this.lastUtc = const Value.absent(),
    this.durS = const Value.absent(),
    this.lat = const Value.absent(),
    this.lon = const Value.absent(),
    this.maxH = const Value.absent(),
    this.peakRssi = const Value.absent(),
    this.authState = const Value.absent(),
    this.tfr = const Value.absent(),
    this.inTfr = const Value.absent(),
    this.tfrId = const Value.absent(),
    this.classType = const Value.absent(),
    this.catEu = const Value.absent(),
    this.classEu = const Value.absent(),
    this.emerg = const Value.absent(),
    this.msgs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DetectionsCompanion.insert({
    required String detectorId,
    required String rowKey,
    this.seq = const Value.absent(),
    this.active = const Value.absent(),
    this.uasId = const Value.absent(),
    required String mac,
    this.srcs = const Value.absent(),
    this.fmts = const Value.absent(),
    this.uaType = const Value.absent(),
    required int firstUtc,
    required int lastUtc,
    required int durS,
    this.lat = const Value.absent(),
    this.lon = const Value.absent(),
    this.maxH = const Value.absent(),
    this.peakRssi = const Value.absent(),
    this.authState = const Value.absent(),
    required bool tfr,
    this.inTfr = const Value.absent(),
    this.tfrId = const Value.absent(),
    this.classType = const Value.absent(),
    this.catEu = const Value.absent(),
    this.classEu = const Value.absent(),
    required bool emerg,
    required int msgs,
    this.rowid = const Value.absent(),
  })  : detectorId = Value(detectorId),
        rowKey = Value(rowKey),
        mac = Value(mac),
        firstUtc = Value(firstUtc),
        lastUtc = Value(lastUtc),
        durS = Value(durS),
        tfr = Value(tfr),
        emerg = Value(emerg),
        msgs = Value(msgs);
  static Insertable<DetectionEntry> custom({
    Expression<String>? detectorId,
    Expression<String>? rowKey,
    Expression<int>? seq,
    Expression<bool>? active,
    Expression<String>? uasId,
    Expression<String>? mac,
    Expression<int>? srcs,
    Expression<int>? fmts,
    Expression<int>? uaType,
    Expression<int>? firstUtc,
    Expression<int>? lastUtc,
    Expression<int>? durS,
    Expression<double>? lat,
    Expression<double>? lon,
    Expression<double>? maxH,
    Expression<int>? peakRssi,
    Expression<String>? authState,
    Expression<bool>? tfr,
    Expression<bool>? inTfr,
    Expression<String>? tfrId,
    Expression<int>? classType,
    Expression<int>? catEu,
    Expression<int>? classEu,
    Expression<bool>? emerg,
    Expression<int>? msgs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (detectorId != null) 'detector_id': detectorId,
      if (rowKey != null) 'row_key': rowKey,
      if (seq != null) 'seq': seq,
      if (active != null) 'active': active,
      if (uasId != null) 'uas_id': uasId,
      if (mac != null) 'mac': mac,
      if (srcs != null) 'srcs': srcs,
      if (fmts != null) 'fmts': fmts,
      if (uaType != null) 'ua_type': uaType,
      if (firstUtc != null) 'first_utc': firstUtc,
      if (lastUtc != null) 'last_utc': lastUtc,
      if (durS != null) 'dur_s': durS,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (maxH != null) 'max_h': maxH,
      if (peakRssi != null) 'peak_rssi': peakRssi,
      if (authState != null) 'auth_state': authState,
      if (tfr != null) 'tfr': tfr,
      if (inTfr != null) 'in_tfr': inTfr,
      if (tfrId != null) 'tfr_id': tfrId,
      if (classType != null) 'class_type': classType,
      if (catEu != null) 'cat_eu': catEu,
      if (classEu != null) 'class_eu': classEu,
      if (emerg != null) 'emerg': emerg,
      if (msgs != null) 'msgs': msgs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DetectionsCompanion copyWith(
      {Value<String>? detectorId,
      Value<String>? rowKey,
      Value<int?>? seq,
      Value<bool>? active,
      Value<String?>? uasId,
      Value<String>? mac,
      Value<int?>? srcs,
      Value<int?>? fmts,
      Value<int?>? uaType,
      Value<int>? firstUtc,
      Value<int>? lastUtc,
      Value<int>? durS,
      Value<double?>? lat,
      Value<double?>? lon,
      Value<double?>? maxH,
      Value<int?>? peakRssi,
      Value<String>? authState,
      Value<bool>? tfr,
      Value<bool?>? inTfr,
      Value<String?>? tfrId,
      Value<int?>? classType,
      Value<int?>? catEu,
      Value<int?>? classEu,
      Value<bool>? emerg,
      Value<int>? msgs,
      Value<int>? rowid}) {
    return DetectionsCompanion(
      detectorId: detectorId ?? this.detectorId,
      rowKey: rowKey ?? this.rowKey,
      seq: seq ?? this.seq,
      active: active ?? this.active,
      uasId: uasId ?? this.uasId,
      mac: mac ?? this.mac,
      srcs: srcs ?? this.srcs,
      fmts: fmts ?? this.fmts,
      uaType: uaType ?? this.uaType,
      firstUtc: firstUtc ?? this.firstUtc,
      lastUtc: lastUtc ?? this.lastUtc,
      durS: durS ?? this.durS,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      maxH: maxH ?? this.maxH,
      peakRssi: peakRssi ?? this.peakRssi,
      authState: authState ?? this.authState,
      tfr: tfr ?? this.tfr,
      inTfr: inTfr ?? this.inTfr,
      tfrId: tfrId ?? this.tfrId,
      classType: classType ?? this.classType,
      catEu: catEu ?? this.catEu,
      classEu: classEu ?? this.classEu,
      emerg: emerg ?? this.emerg,
      msgs: msgs ?? this.msgs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (detectorId.present) {
      map['detector_id'] = Variable<String>(detectorId.value);
    }
    if (rowKey.present) {
      map['row_key'] = Variable<String>(rowKey.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (active.present) {
      map['active'] = Variable<bool>(active.value);
    }
    if (uasId.present) {
      map['uas_id'] = Variable<String>(uasId.value);
    }
    if (mac.present) {
      map['mac'] = Variable<String>(mac.value);
    }
    if (srcs.present) {
      map['srcs'] = Variable<int>(srcs.value);
    }
    if (fmts.present) {
      map['fmts'] = Variable<int>(fmts.value);
    }
    if (uaType.present) {
      map['ua_type'] = Variable<int>(uaType.value);
    }
    if (firstUtc.present) {
      map['first_utc'] = Variable<int>(firstUtc.value);
    }
    if (lastUtc.present) {
      map['last_utc'] = Variable<int>(lastUtc.value);
    }
    if (durS.present) {
      map['dur_s'] = Variable<int>(durS.value);
    }
    if (lat.present) {
      map['lat'] = Variable<double>(lat.value);
    }
    if (lon.present) {
      map['lon'] = Variable<double>(lon.value);
    }
    if (maxH.present) {
      map['max_h'] = Variable<double>(maxH.value);
    }
    if (peakRssi.present) {
      map['peak_rssi'] = Variable<int>(peakRssi.value);
    }
    if (authState.present) {
      map['auth_state'] = Variable<String>(authState.value);
    }
    if (tfr.present) {
      map['tfr'] = Variable<bool>(tfr.value);
    }
    if (inTfr.present) {
      map['in_tfr'] = Variable<bool>(inTfr.value);
    }
    if (tfrId.present) {
      map['tfr_id'] = Variable<String>(tfrId.value);
    }
    if (classType.present) {
      map['class_type'] = Variable<int>(classType.value);
    }
    if (catEu.present) {
      map['cat_eu'] = Variable<int>(catEu.value);
    }
    if (classEu.present) {
      map['class_eu'] = Variable<int>(classEu.value);
    }
    if (emerg.present) {
      map['emerg'] = Variable<bool>(emerg.value);
    }
    if (msgs.present) {
      map['msgs'] = Variable<int>(msgs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DetectionsCompanion(')
          ..write('detectorId: $detectorId, ')
          ..write('rowKey: $rowKey, ')
          ..write('seq: $seq, ')
          ..write('active: $active, ')
          ..write('uasId: $uasId, ')
          ..write('mac: $mac, ')
          ..write('srcs: $srcs, ')
          ..write('fmts: $fmts, ')
          ..write('uaType: $uaType, ')
          ..write('firstUtc: $firstUtc, ')
          ..write('lastUtc: $lastUtc, ')
          ..write('durS: $durS, ')
          ..write('lat: $lat, ')
          ..write('lon: $lon, ')
          ..write('maxH: $maxH, ')
          ..write('peakRssi: $peakRssi, ')
          ..write('authState: $authState, ')
          ..write('tfr: $tfr, ')
          ..write('inTfr: $inTfr, ')
          ..write('tfrId: $tfrId, ')
          ..write('classType: $classType, ')
          ..write('catEu: $catEu, ')
          ..write('classEu: $classEu, ')
          ..write('emerg: $emerg, ')
          ..write('msgs: $msgs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LivePointsTable extends LivePoints
    with TableInfo<$LivePointsTable, LivePointEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LivePointsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _detectorIdMeta =
      const VerificationMeta('detectorId');
  @override
  late final GeneratedColumn<String> detectorId = GeneratedColumn<String>(
      'detector_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _uasKeyMeta = const VerificationMeta('uasKey');
  @override
  late final GeneratedColumn<String> uasKey = GeneratedColumn<String>(
      'uas_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _timestampMeta =
      const VerificationMeta('timestamp');
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
      'timestamp', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _latMeta = const VerificationMeta('lat');
  @override
  late final GeneratedColumn<double> lat = GeneratedColumn<double>(
      'lat', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _lonMeta = const VerificationMeta('lon');
  @override
  late final GeneratedColumn<double> lon = GeneratedColumn<double>(
      'lon', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<double> height = GeneratedColumn<double>(
      'height', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _rssiMeta = const VerificationMeta('rssi');
  @override
  late final GeneratedColumn<int> rssi = GeneratedColumn<int>(
      'rssi', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, detectorId, uasKey, timestamp, lat, lon, height, rssi];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'live_points';
  @override
  VerificationContext validateIntegrity(Insertable<LivePointEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('detector_id')) {
      context.handle(
          _detectorIdMeta,
          detectorId.isAcceptableOrUnknown(
              data['detector_id']!, _detectorIdMeta));
    } else if (isInserting) {
      context.missing(_detectorIdMeta);
    }
    if (data.containsKey('uas_key')) {
      context.handle(_uasKeyMeta,
          uasKey.isAcceptableOrUnknown(data['uas_key']!, _uasKeyMeta));
    } else if (isInserting) {
      context.missing(_uasKeyMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(_timestampMeta,
          timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta));
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('lat')) {
      context.handle(
          _latMeta, lat.isAcceptableOrUnknown(data['lat']!, _latMeta));
    }
    if (data.containsKey('lon')) {
      context.handle(
          _lonMeta, lon.isAcceptableOrUnknown(data['lon']!, _lonMeta));
    }
    if (data.containsKey('height')) {
      context.handle(_heightMeta,
          height.isAcceptableOrUnknown(data['height']!, _heightMeta));
    }
    if (data.containsKey('rssi')) {
      context.handle(
          _rssiMeta, rssi.isAcceptableOrUnknown(data['rssi']!, _rssiMeta));
    } else if (isInserting) {
      context.missing(_rssiMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LivePointEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LivePointEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      detectorId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}detector_id'])!,
      uasKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uas_key'])!,
      timestamp: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}timestamp'])!,
      lat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lat']),
      lon: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lon']),
      height: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}height']),
      rssi: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}rssi'])!,
    );
  }

  @override
  $LivePointsTable createAlias(String alias) {
    return $LivePointsTable(attachedDatabase, alias);
  }
}

class LivePointEntry extends DataClass implements Insertable<LivePointEntry> {
  final int id;
  final String detectorId;
  final String uasKey;
  final int timestamp;
  final double? lat;
  final double? lon;
  final double? height;
  final int rssi;
  const LivePointEntry(
      {required this.id,
      required this.detectorId,
      required this.uasKey,
      required this.timestamp,
      this.lat,
      this.lon,
      this.height,
      required this.rssi});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['detector_id'] = Variable<String>(detectorId);
    map['uas_key'] = Variable<String>(uasKey);
    map['timestamp'] = Variable<int>(timestamp);
    if (!nullToAbsent || lat != null) {
      map['lat'] = Variable<double>(lat);
    }
    if (!nullToAbsent || lon != null) {
      map['lon'] = Variable<double>(lon);
    }
    if (!nullToAbsent || height != null) {
      map['height'] = Variable<double>(height);
    }
    map['rssi'] = Variable<int>(rssi);
    return map;
  }

  LivePointsCompanion toCompanion(bool nullToAbsent) {
    return LivePointsCompanion(
      id: Value(id),
      detectorId: Value(detectorId),
      uasKey: Value(uasKey),
      timestamp: Value(timestamp),
      lat: lat == null && nullToAbsent ? const Value.absent() : Value(lat),
      lon: lon == null && nullToAbsent ? const Value.absent() : Value(lon),
      height:
          height == null && nullToAbsent ? const Value.absent() : Value(height),
      rssi: Value(rssi),
    );
  }

  factory LivePointEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LivePointEntry(
      id: serializer.fromJson<int>(json['id']),
      detectorId: serializer.fromJson<String>(json['detectorId']),
      uasKey: serializer.fromJson<String>(json['uasKey']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      lat: serializer.fromJson<double?>(json['lat']),
      lon: serializer.fromJson<double?>(json['lon']),
      height: serializer.fromJson<double?>(json['height']),
      rssi: serializer.fromJson<int>(json['rssi']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'detectorId': serializer.toJson<String>(detectorId),
      'uasKey': serializer.toJson<String>(uasKey),
      'timestamp': serializer.toJson<int>(timestamp),
      'lat': serializer.toJson<double?>(lat),
      'lon': serializer.toJson<double?>(lon),
      'height': serializer.toJson<double?>(height),
      'rssi': serializer.toJson<int>(rssi),
    };
  }

  LivePointEntry copyWith(
          {int? id,
          String? detectorId,
          String? uasKey,
          int? timestamp,
          Value<double?> lat = const Value.absent(),
          Value<double?> lon = const Value.absent(),
          Value<double?> height = const Value.absent(),
          int? rssi}) =>
      LivePointEntry(
        id: id ?? this.id,
        detectorId: detectorId ?? this.detectorId,
        uasKey: uasKey ?? this.uasKey,
        timestamp: timestamp ?? this.timestamp,
        lat: lat.present ? lat.value : this.lat,
        lon: lon.present ? lon.value : this.lon,
        height: height.present ? height.value : this.height,
        rssi: rssi ?? this.rssi,
      );
  LivePointEntry copyWithCompanion(LivePointsCompanion data) {
    return LivePointEntry(
      id: data.id.present ? data.id.value : this.id,
      detectorId:
          data.detectorId.present ? data.detectorId.value : this.detectorId,
      uasKey: data.uasKey.present ? data.uasKey.value : this.uasKey,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      lat: data.lat.present ? data.lat.value : this.lat,
      lon: data.lon.present ? data.lon.value : this.lon,
      height: data.height.present ? data.height.value : this.height,
      rssi: data.rssi.present ? data.rssi.value : this.rssi,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LivePointEntry(')
          ..write('id: $id, ')
          ..write('detectorId: $detectorId, ')
          ..write('uasKey: $uasKey, ')
          ..write('timestamp: $timestamp, ')
          ..write('lat: $lat, ')
          ..write('lon: $lon, ')
          ..write('height: $height, ')
          ..write('rssi: $rssi')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, detectorId, uasKey, timestamp, lat, lon, height, rssi);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LivePointEntry &&
          other.id == this.id &&
          other.detectorId == this.detectorId &&
          other.uasKey == this.uasKey &&
          other.timestamp == this.timestamp &&
          other.lat == this.lat &&
          other.lon == this.lon &&
          other.height == this.height &&
          other.rssi == this.rssi);
}

class LivePointsCompanion extends UpdateCompanion<LivePointEntry> {
  final Value<int> id;
  final Value<String> detectorId;
  final Value<String> uasKey;
  final Value<int> timestamp;
  final Value<double?> lat;
  final Value<double?> lon;
  final Value<double?> height;
  final Value<int> rssi;
  const LivePointsCompanion({
    this.id = const Value.absent(),
    this.detectorId = const Value.absent(),
    this.uasKey = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.lat = const Value.absent(),
    this.lon = const Value.absent(),
    this.height = const Value.absent(),
    this.rssi = const Value.absent(),
  });
  LivePointsCompanion.insert({
    this.id = const Value.absent(),
    required String detectorId,
    required String uasKey,
    required int timestamp,
    this.lat = const Value.absent(),
    this.lon = const Value.absent(),
    this.height = const Value.absent(),
    required int rssi,
  })  : detectorId = Value(detectorId),
        uasKey = Value(uasKey),
        timestamp = Value(timestamp),
        rssi = Value(rssi);
  static Insertable<LivePointEntry> custom({
    Expression<int>? id,
    Expression<String>? detectorId,
    Expression<String>? uasKey,
    Expression<int>? timestamp,
    Expression<double>? lat,
    Expression<double>? lon,
    Expression<double>? height,
    Expression<int>? rssi,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (detectorId != null) 'detector_id': detectorId,
      if (uasKey != null) 'uas_key': uasKey,
      if (timestamp != null) 'timestamp': timestamp,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (height != null) 'height': height,
      if (rssi != null) 'rssi': rssi,
    });
  }

  LivePointsCompanion copyWith(
      {Value<int>? id,
      Value<String>? detectorId,
      Value<String>? uasKey,
      Value<int>? timestamp,
      Value<double?>? lat,
      Value<double?>? lon,
      Value<double?>? height,
      Value<int>? rssi}) {
    return LivePointsCompanion(
      id: id ?? this.id,
      detectorId: detectorId ?? this.detectorId,
      uasKey: uasKey ?? this.uasKey,
      timestamp: timestamp ?? this.timestamp,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      height: height ?? this.height,
      rssi: rssi ?? this.rssi,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (detectorId.present) {
      map['detector_id'] = Variable<String>(detectorId.value);
    }
    if (uasKey.present) {
      map['uas_key'] = Variable<String>(uasKey.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (lat.present) {
      map['lat'] = Variable<double>(lat.value);
    }
    if (lon.present) {
      map['lon'] = Variable<double>(lon.value);
    }
    if (height.present) {
      map['height'] = Variable<double>(height.value);
    }
    if (rssi.present) {
      map['rssi'] = Variable<int>(rssi.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LivePointsCompanion(')
          ..write('id: $id, ')
          ..write('detectorId: $detectorId, ')
          ..write('uasKey: $uasKey, ')
          ..write('timestamp: $timestamp, ')
          ..write('lat: $lat, ')
          ..write('lon: $lon, ')
          ..write('height: $height, ')
          ..write('rssi: $rssi')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings
    with TableInfo<$SettingsTable, SettingEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(Insertable<SettingEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SettingEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingEntry(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class SettingEntry extends DataClass implements Insertable<SettingEntry> {
  final String key;
  final String value;
  const SettingEntry({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(
      key: Value(key),
      value: Value(value),
    );
  }

  factory SettingEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingEntry(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  SettingEntry copyWith({String? key, String? value}) => SettingEntry(
        key: key ?? this.key,
        value: value ?? this.value,
      );
  SettingEntry copyWithCompanion(SettingsCompanion data) {
    return SettingEntry(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingEntry(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingEntry &&
          other.key == this.key &&
          other.value == this.value);
}

class SettingsCompanion extends UpdateCompanion<SettingEntry> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<SettingEntry> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith(
      {Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return SettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $DetectorsTable detectors = $DetectorsTable(this);
  late final $DetectionsTable detections = $DetectionsTable(this);
  late final $LivePointsTable livePoints = $LivePointsTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [detectors, detections, livePoints, settings];
}

typedef $$DetectorsTableCreateCompanionBuilder = DetectorsCompanion Function({
  required String id,
  required String name,
  Value<String> board,
  Value<String> fw,
  Value<String> ver,
  Value<String> caps,
  Value<int> lastSeen,
  Value<int> lastSyncSeq,
  Value<int?> oldestSeq,
  Value<bool> bonded,
  Value<int?> lastSyncUtc,
  Value<bool> historyGap,
  Value<int> logEpoch,
  Value<int?> logId,
  Value<int> rowid,
});
typedef $$DetectorsTableUpdateCompanionBuilder = DetectorsCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String> board,
  Value<String> fw,
  Value<String> ver,
  Value<String> caps,
  Value<int> lastSeen,
  Value<int> lastSyncSeq,
  Value<int?> oldestSeq,
  Value<bool> bonded,
  Value<int?> lastSyncUtc,
  Value<bool> historyGap,
  Value<int> logEpoch,
  Value<int?> logId,
  Value<int> rowid,
});

class $$DetectorsTableFilterComposer
    extends Composer<_$AppDatabase, $DetectorsTable> {
  $$DetectorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get board => $composableBuilder(
      column: $table.board, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fw => $composableBuilder(
      column: $table.fw, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ver => $composableBuilder(
      column: $table.ver, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get caps => $composableBuilder(
      column: $table.caps, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastSeen => $composableBuilder(
      column: $table.lastSeen, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastSyncSeq => $composableBuilder(
      column: $table.lastSyncSeq, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get oldestSeq => $composableBuilder(
      column: $table.oldestSeq, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get bonded => $composableBuilder(
      column: $table.bonded, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastSyncUtc => $composableBuilder(
      column: $table.lastSyncUtc, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get historyGap => $composableBuilder(
      column: $table.historyGap, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get logEpoch => $composableBuilder(
      column: $table.logEpoch, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get logId => $composableBuilder(
      column: $table.logId, builder: (column) => ColumnFilters(column));
}

class $$DetectorsTableOrderingComposer
    extends Composer<_$AppDatabase, $DetectorsTable> {
  $$DetectorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get board => $composableBuilder(
      column: $table.board, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fw => $composableBuilder(
      column: $table.fw, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ver => $composableBuilder(
      column: $table.ver, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get caps => $composableBuilder(
      column: $table.caps, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastSeen => $composableBuilder(
      column: $table.lastSeen, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastSyncSeq => $composableBuilder(
      column: $table.lastSyncSeq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get oldestSeq => $composableBuilder(
      column: $table.oldestSeq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get bonded => $composableBuilder(
      column: $table.bonded, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastSyncUtc => $composableBuilder(
      column: $table.lastSyncUtc, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get historyGap => $composableBuilder(
      column: $table.historyGap, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get logEpoch => $composableBuilder(
      column: $table.logEpoch, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get logId => $composableBuilder(
      column: $table.logId, builder: (column) => ColumnOrderings(column));
}

class $$DetectorsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DetectorsTable> {
  $$DetectorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get board =>
      $composableBuilder(column: $table.board, builder: (column) => column);

  GeneratedColumn<String> get fw =>
      $composableBuilder(column: $table.fw, builder: (column) => column);

  GeneratedColumn<String> get ver =>
      $composableBuilder(column: $table.ver, builder: (column) => column);

  GeneratedColumn<String> get caps =>
      $composableBuilder(column: $table.caps, builder: (column) => column);

  GeneratedColumn<int> get lastSeen =>
      $composableBuilder(column: $table.lastSeen, builder: (column) => column);

  GeneratedColumn<int> get lastSyncSeq => $composableBuilder(
      column: $table.lastSyncSeq, builder: (column) => column);

  GeneratedColumn<int> get oldestSeq =>
      $composableBuilder(column: $table.oldestSeq, builder: (column) => column);

  GeneratedColumn<bool> get bonded =>
      $composableBuilder(column: $table.bonded, builder: (column) => column);

  GeneratedColumn<int> get lastSyncUtc => $composableBuilder(
      column: $table.lastSyncUtc, builder: (column) => column);

  GeneratedColumn<bool> get historyGap => $composableBuilder(
      column: $table.historyGap, builder: (column) => column);

  GeneratedColumn<int> get logEpoch =>
      $composableBuilder(column: $table.logEpoch, builder: (column) => column);

  GeneratedColumn<int> get logId =>
      $composableBuilder(column: $table.logId, builder: (column) => column);
}

class $$DetectorsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DetectorsTable,
    DetectorEntry,
    $$DetectorsTableFilterComposer,
    $$DetectorsTableOrderingComposer,
    $$DetectorsTableAnnotationComposer,
    $$DetectorsTableCreateCompanionBuilder,
    $$DetectorsTableUpdateCompanionBuilder,
    (
      DetectorEntry,
      BaseReferences<_$AppDatabase, $DetectorsTable, DetectorEntry>
    ),
    DetectorEntry,
    PrefetchHooks Function()> {
  $$DetectorsTableTableManager(_$AppDatabase db, $DetectorsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DetectorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DetectorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DetectorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> board = const Value.absent(),
            Value<String> fw = const Value.absent(),
            Value<String> ver = const Value.absent(),
            Value<String> caps = const Value.absent(),
            Value<int> lastSeen = const Value.absent(),
            Value<int> lastSyncSeq = const Value.absent(),
            Value<int?> oldestSeq = const Value.absent(),
            Value<bool> bonded = const Value.absent(),
            Value<int?> lastSyncUtc = const Value.absent(),
            Value<bool> historyGap = const Value.absent(),
            Value<int> logEpoch = const Value.absent(),
            Value<int?> logId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DetectorsCompanion(
            id: id,
            name: name,
            board: board,
            fw: fw,
            ver: ver,
            caps: caps,
            lastSeen: lastSeen,
            lastSyncSeq: lastSyncSeq,
            oldestSeq: oldestSeq,
            bonded: bonded,
            lastSyncUtc: lastSyncUtc,
            historyGap: historyGap,
            logEpoch: logEpoch,
            logId: logId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String name,
            Value<String> board = const Value.absent(),
            Value<String> fw = const Value.absent(),
            Value<String> ver = const Value.absent(),
            Value<String> caps = const Value.absent(),
            Value<int> lastSeen = const Value.absent(),
            Value<int> lastSyncSeq = const Value.absent(),
            Value<int?> oldestSeq = const Value.absent(),
            Value<bool> bonded = const Value.absent(),
            Value<int?> lastSyncUtc = const Value.absent(),
            Value<bool> historyGap = const Value.absent(),
            Value<int> logEpoch = const Value.absent(),
            Value<int?> logId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DetectorsCompanion.insert(
            id: id,
            name: name,
            board: board,
            fw: fw,
            ver: ver,
            caps: caps,
            lastSeen: lastSeen,
            lastSyncSeq: lastSyncSeq,
            oldestSeq: oldestSeq,
            bonded: bonded,
            lastSyncUtc: lastSyncUtc,
            historyGap: historyGap,
            logEpoch: logEpoch,
            logId: logId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$DetectorsTable, DetectorEntry>(table),
                    BaseReferences<_$AppDatabase, $DetectorsTable,
                        DetectorEntry>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DetectorsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DetectorsTable,
    DetectorEntry,
    $$DetectorsTableFilterComposer,
    $$DetectorsTableOrderingComposer,
    $$DetectorsTableAnnotationComposer,
    $$DetectorsTableCreateCompanionBuilder,
    $$DetectorsTableUpdateCompanionBuilder,
    (
      DetectorEntry,
      BaseReferences<_$AppDatabase, $DetectorsTable, DetectorEntry>
    ),
    DetectorEntry,
    PrefetchHooks Function()>;
typedef $$DetectionsTableCreateCompanionBuilder = DetectionsCompanion Function({
  required String detectorId,
  required String rowKey,
  Value<int?> seq,
  Value<bool> active,
  Value<String?> uasId,
  required String mac,
  Value<int?> srcs,
  Value<int?> fmts,
  Value<int?> uaType,
  required int firstUtc,
  required int lastUtc,
  required int durS,
  Value<double?> lat,
  Value<double?> lon,
  Value<double?> maxH,
  Value<int?> peakRssi,
  Value<String> authState,
  required bool tfr,
  Value<bool?> inTfr,
  Value<String?> tfrId,
  Value<int?> classType,
  Value<int?> catEu,
  Value<int?> classEu,
  required bool emerg,
  required int msgs,
  Value<int> rowid,
});
typedef $$DetectionsTableUpdateCompanionBuilder = DetectionsCompanion Function({
  Value<String> detectorId,
  Value<String> rowKey,
  Value<int?> seq,
  Value<bool> active,
  Value<String?> uasId,
  Value<String> mac,
  Value<int?> srcs,
  Value<int?> fmts,
  Value<int?> uaType,
  Value<int> firstUtc,
  Value<int> lastUtc,
  Value<int> durS,
  Value<double?> lat,
  Value<double?> lon,
  Value<double?> maxH,
  Value<int?> peakRssi,
  Value<String> authState,
  Value<bool> tfr,
  Value<bool?> inTfr,
  Value<String?> tfrId,
  Value<int?> classType,
  Value<int?> catEu,
  Value<int?> classEu,
  Value<bool> emerg,
  Value<int> msgs,
  Value<int> rowid,
});

class $$DetectionsTableFilterComposer
    extends Composer<_$AppDatabase, $DetectionsTable> {
  $$DetectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get detectorId => $composableBuilder(
      column: $table.detectorId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get rowKey => $composableBuilder(
      column: $table.rowKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get seq => $composableBuilder(
      column: $table.seq, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get active => $composableBuilder(
      column: $table.active, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uasId => $composableBuilder(
      column: $table.uasId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mac => $composableBuilder(
      column: $table.mac, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get srcs => $composableBuilder(
      column: $table.srcs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get fmts => $composableBuilder(
      column: $table.fmts, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get uaType => $composableBuilder(
      column: $table.uaType, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get firstUtc => $composableBuilder(
      column: $table.firstUtc, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastUtc => $composableBuilder(
      column: $table.lastUtc, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durS => $composableBuilder(
      column: $table.durS, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lon => $composableBuilder(
      column: $table.lon, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get maxH => $composableBuilder(
      column: $table.maxH, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get peakRssi => $composableBuilder(
      column: $table.peakRssi, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get authState => $composableBuilder(
      column: $table.authState, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get tfr => $composableBuilder(
      column: $table.tfr, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get inTfr => $composableBuilder(
      column: $table.inTfr, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tfrId => $composableBuilder(
      column: $table.tfrId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get classType => $composableBuilder(
      column: $table.classType, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get catEu => $composableBuilder(
      column: $table.catEu, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get classEu => $composableBuilder(
      column: $table.classEu, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get emerg => $composableBuilder(
      column: $table.emerg, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get msgs => $composableBuilder(
      column: $table.msgs, builder: (column) => ColumnFilters(column));
}

class $$DetectionsTableOrderingComposer
    extends Composer<_$AppDatabase, $DetectionsTable> {
  $$DetectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get detectorId => $composableBuilder(
      column: $table.detectorId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get rowKey => $composableBuilder(
      column: $table.rowKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get seq => $composableBuilder(
      column: $table.seq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get active => $composableBuilder(
      column: $table.active, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uasId => $composableBuilder(
      column: $table.uasId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mac => $composableBuilder(
      column: $table.mac, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get srcs => $composableBuilder(
      column: $table.srcs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get fmts => $composableBuilder(
      column: $table.fmts, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get uaType => $composableBuilder(
      column: $table.uaType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get firstUtc => $composableBuilder(
      column: $table.firstUtc, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastUtc => $composableBuilder(
      column: $table.lastUtc, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durS => $composableBuilder(
      column: $table.durS, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lon => $composableBuilder(
      column: $table.lon, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get maxH => $composableBuilder(
      column: $table.maxH, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get peakRssi => $composableBuilder(
      column: $table.peakRssi, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get authState => $composableBuilder(
      column: $table.authState, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get tfr => $composableBuilder(
      column: $table.tfr, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get inTfr => $composableBuilder(
      column: $table.inTfr, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tfrId => $composableBuilder(
      column: $table.tfrId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get classType => $composableBuilder(
      column: $table.classType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get catEu => $composableBuilder(
      column: $table.catEu, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get classEu => $composableBuilder(
      column: $table.classEu, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get emerg => $composableBuilder(
      column: $table.emerg, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get msgs => $composableBuilder(
      column: $table.msgs, builder: (column) => ColumnOrderings(column));
}

class $$DetectionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DetectionsTable> {
  $$DetectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get detectorId => $composableBuilder(
      column: $table.detectorId, builder: (column) => column);

  GeneratedColumn<String> get rowKey =>
      $composableBuilder(column: $table.rowKey, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<bool> get active =>
      $composableBuilder(column: $table.active, builder: (column) => column);

  GeneratedColumn<String> get uasId =>
      $composableBuilder(column: $table.uasId, builder: (column) => column);

  GeneratedColumn<String> get mac =>
      $composableBuilder(column: $table.mac, builder: (column) => column);

  GeneratedColumn<int> get srcs =>
      $composableBuilder(column: $table.srcs, builder: (column) => column);

  GeneratedColumn<int> get fmts =>
      $composableBuilder(column: $table.fmts, builder: (column) => column);

  GeneratedColumn<int> get uaType =>
      $composableBuilder(column: $table.uaType, builder: (column) => column);

  GeneratedColumn<int> get firstUtc =>
      $composableBuilder(column: $table.firstUtc, builder: (column) => column);

  GeneratedColumn<int> get lastUtc =>
      $composableBuilder(column: $table.lastUtc, builder: (column) => column);

  GeneratedColumn<int> get durS =>
      $composableBuilder(column: $table.durS, builder: (column) => column);

  GeneratedColumn<double> get lat =>
      $composableBuilder(column: $table.lat, builder: (column) => column);

  GeneratedColumn<double> get lon =>
      $composableBuilder(column: $table.lon, builder: (column) => column);

  GeneratedColumn<double> get maxH =>
      $composableBuilder(column: $table.maxH, builder: (column) => column);

  GeneratedColumn<int> get peakRssi =>
      $composableBuilder(column: $table.peakRssi, builder: (column) => column);

  GeneratedColumn<String> get authState =>
      $composableBuilder(column: $table.authState, builder: (column) => column);

  GeneratedColumn<bool> get tfr =>
      $composableBuilder(column: $table.tfr, builder: (column) => column);

  GeneratedColumn<bool> get inTfr =>
      $composableBuilder(column: $table.inTfr, builder: (column) => column);

  GeneratedColumn<String> get tfrId =>
      $composableBuilder(column: $table.tfrId, builder: (column) => column);

  GeneratedColumn<int> get classType =>
      $composableBuilder(column: $table.classType, builder: (column) => column);

  GeneratedColumn<int> get catEu =>
      $composableBuilder(column: $table.catEu, builder: (column) => column);

  GeneratedColumn<int> get classEu =>
      $composableBuilder(column: $table.classEu, builder: (column) => column);

  GeneratedColumn<bool> get emerg =>
      $composableBuilder(column: $table.emerg, builder: (column) => column);

  GeneratedColumn<int> get msgs =>
      $composableBuilder(column: $table.msgs, builder: (column) => column);
}

class $$DetectionsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DetectionsTable,
    DetectionEntry,
    $$DetectionsTableFilterComposer,
    $$DetectionsTableOrderingComposer,
    $$DetectionsTableAnnotationComposer,
    $$DetectionsTableCreateCompanionBuilder,
    $$DetectionsTableUpdateCompanionBuilder,
    (
      DetectionEntry,
      BaseReferences<_$AppDatabase, $DetectionsTable, DetectionEntry>
    ),
    DetectionEntry,
    PrefetchHooks Function()> {
  $$DetectionsTableTableManager(_$AppDatabase db, $DetectionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DetectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DetectionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DetectionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> detectorId = const Value.absent(),
            Value<String> rowKey = const Value.absent(),
            Value<int?> seq = const Value.absent(),
            Value<bool> active = const Value.absent(),
            Value<String?> uasId = const Value.absent(),
            Value<String> mac = const Value.absent(),
            Value<int?> srcs = const Value.absent(),
            Value<int?> fmts = const Value.absent(),
            Value<int?> uaType = const Value.absent(),
            Value<int> firstUtc = const Value.absent(),
            Value<int> lastUtc = const Value.absent(),
            Value<int> durS = const Value.absent(),
            Value<double?> lat = const Value.absent(),
            Value<double?> lon = const Value.absent(),
            Value<double?> maxH = const Value.absent(),
            Value<int?> peakRssi = const Value.absent(),
            Value<String> authState = const Value.absent(),
            Value<bool> tfr = const Value.absent(),
            Value<bool?> inTfr = const Value.absent(),
            Value<String?> tfrId = const Value.absent(),
            Value<int?> classType = const Value.absent(),
            Value<int?> catEu = const Value.absent(),
            Value<int?> classEu = const Value.absent(),
            Value<bool> emerg = const Value.absent(),
            Value<int> msgs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DetectionsCompanion(
            detectorId: detectorId,
            rowKey: rowKey,
            seq: seq,
            active: active,
            uasId: uasId,
            mac: mac,
            srcs: srcs,
            fmts: fmts,
            uaType: uaType,
            firstUtc: firstUtc,
            lastUtc: lastUtc,
            durS: durS,
            lat: lat,
            lon: lon,
            maxH: maxH,
            peakRssi: peakRssi,
            authState: authState,
            tfr: tfr,
            inTfr: inTfr,
            tfrId: tfrId,
            classType: classType,
            catEu: catEu,
            classEu: classEu,
            emerg: emerg,
            msgs: msgs,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String detectorId,
            required String rowKey,
            Value<int?> seq = const Value.absent(),
            Value<bool> active = const Value.absent(),
            Value<String?> uasId = const Value.absent(),
            required String mac,
            Value<int?> srcs = const Value.absent(),
            Value<int?> fmts = const Value.absent(),
            Value<int?> uaType = const Value.absent(),
            required int firstUtc,
            required int lastUtc,
            required int durS,
            Value<double?> lat = const Value.absent(),
            Value<double?> lon = const Value.absent(),
            Value<double?> maxH = const Value.absent(),
            Value<int?> peakRssi = const Value.absent(),
            Value<String> authState = const Value.absent(),
            required bool tfr,
            Value<bool?> inTfr = const Value.absent(),
            Value<String?> tfrId = const Value.absent(),
            Value<int?> classType = const Value.absent(),
            Value<int?> catEu = const Value.absent(),
            Value<int?> classEu = const Value.absent(),
            required bool emerg,
            required int msgs,
            Value<int> rowid = const Value.absent(),
          }) =>
              DetectionsCompanion.insert(
            detectorId: detectorId,
            rowKey: rowKey,
            seq: seq,
            active: active,
            uasId: uasId,
            mac: mac,
            srcs: srcs,
            fmts: fmts,
            uaType: uaType,
            firstUtc: firstUtc,
            lastUtc: lastUtc,
            durS: durS,
            lat: lat,
            lon: lon,
            maxH: maxH,
            peakRssi: peakRssi,
            authState: authState,
            tfr: tfr,
            inTfr: inTfr,
            tfrId: tfrId,
            classType: classType,
            catEu: catEu,
            classEu: classEu,
            emerg: emerg,
            msgs: msgs,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$DetectionsTable, DetectionEntry>(table),
                    BaseReferences<_$AppDatabase, $DetectionsTable,
                        DetectionEntry>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DetectionsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DetectionsTable,
    DetectionEntry,
    $$DetectionsTableFilterComposer,
    $$DetectionsTableOrderingComposer,
    $$DetectionsTableAnnotationComposer,
    $$DetectionsTableCreateCompanionBuilder,
    $$DetectionsTableUpdateCompanionBuilder,
    (
      DetectionEntry,
      BaseReferences<_$AppDatabase, $DetectionsTable, DetectionEntry>
    ),
    DetectionEntry,
    PrefetchHooks Function()>;
typedef $$LivePointsTableCreateCompanionBuilder = LivePointsCompanion Function({
  Value<int> id,
  required String detectorId,
  required String uasKey,
  required int timestamp,
  Value<double?> lat,
  Value<double?> lon,
  Value<double?> height,
  required int rssi,
});
typedef $$LivePointsTableUpdateCompanionBuilder = LivePointsCompanion Function({
  Value<int> id,
  Value<String> detectorId,
  Value<String> uasKey,
  Value<int> timestamp,
  Value<double?> lat,
  Value<double?> lon,
  Value<double?> height,
  Value<int> rssi,
});

class $$LivePointsTableFilterComposer
    extends Composer<_$AppDatabase, $LivePointsTable> {
  $$LivePointsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get detectorId => $composableBuilder(
      column: $table.detectorId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uasKey => $composableBuilder(
      column: $table.uasKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lon => $composableBuilder(
      column: $table.lon, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get height => $composableBuilder(
      column: $table.height, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get rssi => $composableBuilder(
      column: $table.rssi, builder: (column) => ColumnFilters(column));
}

class $$LivePointsTableOrderingComposer
    extends Composer<_$AppDatabase, $LivePointsTable> {
  $$LivePointsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get detectorId => $composableBuilder(
      column: $table.detectorId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uasKey => $composableBuilder(
      column: $table.uasKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lon => $composableBuilder(
      column: $table.lon, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get height => $composableBuilder(
      column: $table.height, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get rssi => $composableBuilder(
      column: $table.rssi, builder: (column) => ColumnOrderings(column));
}

class $$LivePointsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LivePointsTable> {
  $$LivePointsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get detectorId => $composableBuilder(
      column: $table.detectorId, builder: (column) => column);

  GeneratedColumn<String> get uasKey =>
      $composableBuilder(column: $table.uasKey, builder: (column) => column);

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<double> get lat =>
      $composableBuilder(column: $table.lat, builder: (column) => column);

  GeneratedColumn<double> get lon =>
      $composableBuilder(column: $table.lon, builder: (column) => column);

  GeneratedColumn<double> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<int> get rssi =>
      $composableBuilder(column: $table.rssi, builder: (column) => column);
}

class $$LivePointsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $LivePointsTable,
    LivePointEntry,
    $$LivePointsTableFilterComposer,
    $$LivePointsTableOrderingComposer,
    $$LivePointsTableAnnotationComposer,
    $$LivePointsTableCreateCompanionBuilder,
    $$LivePointsTableUpdateCompanionBuilder,
    (
      LivePointEntry,
      BaseReferences<_$AppDatabase, $LivePointsTable, LivePointEntry>
    ),
    LivePointEntry,
    PrefetchHooks Function()> {
  $$LivePointsTableTableManager(_$AppDatabase db, $LivePointsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LivePointsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LivePointsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LivePointsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> detectorId = const Value.absent(),
            Value<String> uasKey = const Value.absent(),
            Value<int> timestamp = const Value.absent(),
            Value<double?> lat = const Value.absent(),
            Value<double?> lon = const Value.absent(),
            Value<double?> height = const Value.absent(),
            Value<int> rssi = const Value.absent(),
          }) =>
              LivePointsCompanion(
            id: id,
            detectorId: detectorId,
            uasKey: uasKey,
            timestamp: timestamp,
            lat: lat,
            lon: lon,
            height: height,
            rssi: rssi,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String detectorId,
            required String uasKey,
            required int timestamp,
            Value<double?> lat = const Value.absent(),
            Value<double?> lon = const Value.absent(),
            Value<double?> height = const Value.absent(),
            required int rssi,
          }) =>
              LivePointsCompanion.insert(
            id: id,
            detectorId: detectorId,
            uasKey: uasKey,
            timestamp: timestamp,
            lat: lat,
            lon: lon,
            height: height,
            rssi: rssi,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$LivePointsTable, LivePointEntry>(table),
                    BaseReferences<_$AppDatabase, $LivePointsTable,
                        LivePointEntry>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LivePointsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $LivePointsTable,
    LivePointEntry,
    $$LivePointsTableFilterComposer,
    $$LivePointsTableOrderingComposer,
    $$LivePointsTableAnnotationComposer,
    $$LivePointsTableCreateCompanionBuilder,
    $$LivePointsTableUpdateCompanionBuilder,
    (
      LivePointEntry,
      BaseReferences<_$AppDatabase, $LivePointsTable, LivePointEntry>
    ),
    LivePointEntry,
    PrefetchHooks Function()>;
typedef $$SettingsTableCreateCompanionBuilder = SettingsCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$SettingsTableUpdateCompanionBuilder = SettingsCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SettingsTable,
    SettingEntry,
    $$SettingsTableFilterComposer,
    $$SettingsTableOrderingComposer,
    $$SettingsTableAnnotationComposer,
    $$SettingsTableCreateCompanionBuilder,
    $$SettingsTableUpdateCompanionBuilder,
    (SettingEntry, BaseReferences<_$AppDatabase, $SettingsTable, SettingEntry>),
    SettingEntry,
    PrefetchHooks Function()> {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SettingsCompanion(
            key: key,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              SettingsCompanion.insert(
            key: key,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$SettingsTable, SettingEntry>(table),
                    BaseReferences<_$AppDatabase, $SettingsTable, SettingEntry>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SettingsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SettingsTable,
    SettingEntry,
    $$SettingsTableFilterComposer,
    $$SettingsTableOrderingComposer,
    $$SettingsTableAnnotationComposer,
    $$SettingsTableCreateCompanionBuilder,
    $$SettingsTableUpdateCompanionBuilder,
    (SettingEntry, BaseReferences<_$AppDatabase, $SettingsTable, SettingEntry>),
    SettingEntry,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$DetectorsTableTableManager get detectors =>
      $$DetectorsTableTableManager(_db, _db.detectors);
  $$DetectionsTableTableManager get detections =>
      $$DetectionsTableTableManager(_db, _db.detections);
  $$LivePointsTableTableManager get livePoints =>
      $$LivePointsTableTableManager(_db, _db.livePoints);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
}

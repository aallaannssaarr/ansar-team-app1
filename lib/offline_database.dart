import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

class OfflineDatabase {
  OfflineDatabase._();

  static final OfflineDatabase instance = OfflineDatabase._();

  static const databaseName = 'ansar-products-v1.db';
  static const databaseVersion = 4;

  Database? _database;
  Future<Database>? _openingDatabase;
  final StreamController<String> _changes = StreamController<String>.broadcast();

  Stream<String> get changes => _changes.stream;

  void notifyChanged(String scope) => _changes.add(scope);

  Future<void> initialize() async {
    try {
      await database;
      final integrity = await integrityStatus();
      if (integrity.toLowerCase() != 'ok') {
        await _replaceCorruptDatabase();
      }
    } catch (error) {
      if (_isCorruptionError(error)) {
        await _replaceCorruptDatabase();
      } else {
        rethrow;
      }
    }
    await pruneOldData();
  }

  Future<void> _replaceCorruptDatabase() async {
    final current = _database;
    _database = null;
    await current?.close();
    final root = await getDatabasesPath();
    final path = '$root${Platform.pathSeparator}$databaseName';
    final suffix = DateTime.now().millisecondsSinceEpoch;
    for (final sourcePath in [path, '$path-wal', '$path-shm']) {
      final source = File(sourcePath);
      if (!await source.exists()) continue;
      try {
        await source.rename('$sourcePath.corrupt-$suffix');
      } catch (_) {
        // Preserve a backup when rename is unavailable, then remove the
        // unusable live file so the application can start with a clean DB.
        try {
          await source.copy('$sourcePath.corrupt-$suffix');
          await source.delete();
        } catch (_) {
          // Reopening below will surface the original storage error.
        }
      }
    }
    await database;
  }

  Future<Database> get database async {
    final current = _database;
    if (current != null && current.isOpen) return current;
    final opening = _openingDatabase;
    if (opening != null) return opening;
    final future = _openDatabase();
    _openingDatabase = future;
    try {
      return await future;
    } finally {
      if (identical(_openingDatabase, future)) _openingDatabase = null;
    }
  }

  Future<Database> _openDatabase() async {
    final root = await getDatabasesPath();
    final path = '$root${Platform.pathSeparator}$databaseName';
    final opened = await openDatabase(
      path,
      version: databaseVersion,
      onCreate: (db, _) => _createTables(db),
      onUpgrade: (db, _, __) => _createTables(db),
      onOpen: _createTables,
    );
    _database = opened;
    return opened;
  }

  bool _isCorruptionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('database disk image is malformed') ||
        text.contains('file is not a database') ||
        text.contains('database corrupt') ||
        text.contains('sqlite_corrupt') ||
        text.contains('sqlite_notadb');
  }

  Future<void> _createTables(DatabaseExecutor db) async {
    await db.execute('''
      create table if not exists products (
        mat_num integer primary key,
        normalized_name text not null,
        row_json text not null
      )
    ''');
    await db.execute('create index if not exists products_normalized_name_idx on products(normalized_name)');
    await db.execute('''
      create table if not exists product_barcodes (
        mat_num integer not null,
        barcode text not null,
        primary key (mat_num, barcode)
      )
    ''');
    await db.execute('create index if not exists product_barcodes_barcode_idx on product_barcodes(barcode)');
    await db.execute('''
      create table if not exists products_stage (
        mat_num integer primary key,
        normalized_name text not null,
        row_json text not null
      )
    ''');
    await db.execute('''
      create table if not exists product_barcodes_stage (
        mat_num integer not null,
        barcode text not null,
        primary key (mat_num, barcode)
      )
    ''');
    await db.execute('''
      create table if not exists product_stock (
        mat_num integer not null,
        sto_num integer not null,
        quantity real not null default 0,
        updated_at text,
        primary key (mat_num, sto_num)
      )
    ''');
    await db.execute('create index if not exists product_stock_mat_idx on product_stock(mat_num)');
    await db.execute('''
      create table if not exists product_stock_stage (
        mat_num integer not null,
        sto_num integer not null,
        quantity real not null default 0,
        updated_at text,
        primary key (mat_num, sto_num)
      )
    ''');
    await db.execute('create table if not exists cache_meta (key text primary key, value text)');
    await db.execute('''
      create table if not exists offline_rows (
        scope text not null,
        owner_id text not null default '',
        row_id text not null,
        updated_at text,
        created_at text,
        local_state text,
        row_json text not null,
        primary key (scope, owner_id, row_id)
      )
    ''');
    await db.execute(
      'create index if not exists offline_rows_scope_updated_idx '
      'on offline_rows(scope, owner_id, updated_at desc, row_id)',
    );
    await db.execute('''
      create table if not exists sync_cursors (
        scope text not null,
        owner_id text not null default '',
        cursor_value text not null,
        updated_at text not null,
        primary key (scope, owner_id)
      )
    ''');
    await db.execute('''
      create table if not exists outbox (
        action_id text primary key,
        employee_id text not null,
        action_type text not null,
        entity_id text,
        payload_json text not null,
        state text not null default 'pending',
        attempts integer not null default 0,
        last_error text,
        created_at text not null,
        updated_at text not null,
        next_attempt_at text
      )
    ''');
    await db.execute(
      'create index if not exists outbox_employee_state_idx '
      'on outbox(employee_id, state, next_attempt_at, created_at)',
    );
  }

  Future<void> putRows({
    required String scope,
    required Iterable<Map<String, dynamic>> rows,
    required String Function(Map<String, dynamic>) idOf,
    String ownerId = '',
    String? localState,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final batch = db.batch();
    var count = 0;
    for (final row in rows) {
      final id = idOf(row).trim();
      if (id.isEmpty) continue;
      final updatedAt = _timestamp(row['updated_at'] ?? row['created_at'] ?? row['date']) ?? now;
      batch.insert(
        'offline_rows',
        {
          'scope': scope,
          'owner_id': ownerId,
          'row_id': id,
          'updated_at': updatedAt,
          'created_at': _timestamp(row['created_at'] ?? row['date']) ?? updatedAt,
          'local_state': localState,
          'row_json': jsonEncode(row),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      count++;
    }
    if (count == 0) return;
    await batch.commit(noResult: true);
    _changes.add(scope);
  }

  Future<void> replaceServerRows({
    required String scope,
    required Iterable<Map<String, dynamic>> rows,
    required String Function(Map<String, dynamic>) idOf,
    String ownerId = '',
  }) async {
    final db = await database;
    final values = rows.toList(growable: false);
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((transaction) async {
      await transaction.delete(
        'offline_rows',
        where: "scope = ? and owner_id = ? and local_state is null",
        whereArgs: [scope, ownerId],
      );
      final batch = transaction.batch();
      for (final row in values) {
        final id = idOf(row).trim();
        if (id.isEmpty) continue;
        final updatedAt = _timestamp(row['updated_at'] ?? row['created_at'] ?? row['date']) ?? now;
        batch.insert(
          'offline_rows',
          {
            'scope': scope,
            'owner_id': ownerId,
            'row_id': id,
            'updated_at': updatedAt,
            'created_at': _timestamp(row['created_at'] ?? row['date']) ?? updatedAt,
            'local_state': null,
            'row_json': jsonEncode(row),
          },
          // A server pull must never overwrite an optimistic row that still
          // belongs to an outbox action. Server rows were deleted above, so
          // ignore is enough to preserve pending/conflicting local work while
          // inserting the refreshed server snapshot around it.
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });
    _changes.add(scope);
  }

  Future<List<Map<String, dynamic>>> readRows(
    String scope, {
    String ownerId = '',
    int? limit,
    bool newestFirst = true,
  }) async {
    final db = await database;
    final rows = await db.query(
      'offline_rows',
      columns: ['row_json', 'local_state'],
      where: 'scope = ? and owner_id = ?',
      whereArgs: [scope, ownerId],
      orderBy: 'coalesce(updated_at, created_at) ${newestFirst ? 'desc' : 'asc'}, row_id ${newestFirst ? 'desc' : 'asc'}',
      limit: limit,
    );
    return rows.map((row) {
      try {
        final decoded = jsonDecode(row['row_json']?.toString() ?? '');
        if (decoded is! Map) return null;
        return <String, dynamic>{
          ...Map<String, dynamic>.from(decoded),
          if (row['local_state'] != null) '_local_state': row['local_state'],
        };
      } catch (_) {
        return null;
      }
    }).whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>?> readRow(
    String scope,
    String rowId, {
    String ownerId = '',
  }) async {
    final rows = await (await database).query(
      'offline_rows',
      columns: ['row_json', 'local_state'],
      where: 'scope = ? and owner_id = ? and row_id = ?',
      whereArgs: [scope, ownerId, rowId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      final decoded = jsonDecode(rows.first['row_json']?.toString() ?? '');
      if (decoded is! Map) return null;
      return {
        ...Map<String, dynamic>.from(decoded),
        if (rows.first['local_state'] != null) '_local_state': rows.first['local_state'],
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> removeRow(String scope, String rowId, {String ownerId = ''}) async {
    await (await database).delete(
      'offline_rows',
      where: 'scope = ? and owner_id = ? and row_id = ?',
      whereArgs: [scope, ownerId, rowId],
    );
    _changes.add(scope);
  }

  Future<void> removeLocalRowsWhere(
    String scope, {
    String ownerId = '',
    required bool Function(Map<String, dynamic> row) test,
  }) async {
    final db = await database;
    final rows = await db.query(
      'offline_rows',
      columns: ['row_id', 'row_json'],
      where: 'scope = ? and owner_id = ? and local_state is not null',
      whereArgs: [scope, ownerId],
    );
    final ids = <String>[];
    for (final stored in rows) {
      try {
        final decoded = jsonDecode(stored['row_json']?.toString() ?? '');
        if (decoded is Map && test(Map<String, dynamic>.from(decoded))) {
          ids.add('${stored['row_id']}');
        }
      } catch (_) {
        // A malformed local row is left for the integrity repair path.
      }
    }
    if (ids.isEmpty) return;
    final batch = db.batch();
    for (final id in ids) {
      batch.delete(
        'offline_rows',
        where: 'scope = ? and owner_id = ? and row_id = ?',
        whereArgs: [scope, ownerId, id],
      );
    }
    await batch.commit(noResult: true);
    _changes.add(scope);
  }

  Future<String> queueAction({
    String? actionId,
    required String employeeId,
    required String actionType,
    String? entityId,
    required Map<String, dynamic> payload,
  }) async {
    final id = actionId ?? newClientActionId();
    final now = DateTime.now().toUtc().toIso8601String();
    await (await database).insert(
      'outbox',
      {
        'action_id': id,
        'employee_id': employeeId,
        'action_type': actionType,
        'entity_id': entityId,
        'payload_json': jsonEncode(payload),
        'state': 'pending',
        'attempts': 0,
        'created_at': now,
        'updated_at': now,
        'next_attempt_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _changes.add('outbox');
    return id;
  }

  Future<List<OutboxAction>> dueActions(String employeeId, {int limit = 30}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final rows = await (await database).query(
      'outbox',
      where: "employee_id = ? and state in ('pending', 'retry') and (next_attempt_at is null or next_attempt_at <= ?)",
      whereArgs: [employeeId, now],
      orderBy: 'created_at asc',
      limit: limit,
    );
    return rows.map(OutboxAction.fromRow).toList();
  }

  Future<List<OutboxAction>> actionsForEmployee(String employeeId) async {
    final rows = await (await database).query(
      'outbox',
      where: 'employee_id = ?',
      whereArgs: [employeeId],
      orderBy: "case state when 'conflict' then 0 when 'failed' then 1 else 2 end, created_at desc",
    );
    return rows.map(OutboxAction.fromRow).toList();
  }

  Future<int> pendingActionCount(String employeeId) async {
    final rows = await (await database).rawQuery(
      "select count(*) as count from outbox where employee_id = ? and state <> 'completed'",
      [employeeId],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> recoverInterruptedActions(String employeeId) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final changed = await (await database).update(
      'outbox',
      {
        'state': 'retry',
        'last_error': 'توقفت المحاولة السابقة قبل اكتمالها وسيعاد إرسالها',
        'updated_at': now,
        'next_attempt_at': now,
      },
      where: "employee_id = ? and state = 'sending'",
      whereArgs: [employeeId],
    );
    if (changed > 0) _changes.add('outbox');
  }

  Future<void> clearPrivateRows(String employeeId) async {
    final db = await database;
    await db.transaction((transaction) async {
      await transaction.delete('offline_rows', where: 'owner_id = ?', whereArgs: [employeeId]);
      await transaction.delete('sync_cursors', where: 'owner_id = ?', whereArgs: [employeeId]);
    });
    _changes.add('session');
  }

  Future<void> markActionSending(String actionId) async {
    await (await database).update(
      'outbox',
      {'state': 'sending', 'updated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'action_id = ?',
      whereArgs: [actionId],
    );
    _changes.add('outbox');
  }

  Future<void> updateActionPayload(String actionId, Map<String, dynamic> payload) async {
    await (await database).update(
      'outbox',
      {
        'payload_json': jsonEncode(payload),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'action_id = ?',
      whereArgs: [actionId],
    );
    _changes.add('outbox');
  }

  Future<void> completeAction(String actionId) async {
    await (await database).delete('outbox', where: 'action_id = ?', whereArgs: [actionId]);
    _changes.add('outbox');
  }

  Future<void> failAction(OutboxAction action, Object error, {bool conflict = false}) async {
    final attempts = action.attempts + 1;
    final seconds = min(300, max(5, pow(2, min(attempts, 8)).toInt()));
    final now = DateTime.now().toUtc();
    await (await database).update(
      'outbox',
      {
        'state': conflict ? 'conflict' : 'retry',
        'attempts': attempts,
        'last_error': error.toString(),
        'updated_at': now.toIso8601String(),
        'next_attempt_at': now.add(Duration(seconds: seconds)).toIso8601String(),
      },
      where: 'action_id = ?',
      whereArgs: [action.actionId],
    );
    _changes.add('outbox');
  }

  Future<void> retryAction(String actionId) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await (await database).update(
      'outbox',
      {'state': 'pending', 'last_error': null, 'next_attempt_at': now, 'updated_at': now},
      where: 'action_id = ?',
      whereArgs: [actionId],
    );
    _changes.add('outbox');
  }

  Future<void> setCursor(String scope, String value, {String ownerId = ''}) async {
    await (await database).insert(
      'sync_cursors',
      {
        'scope': scope,
        'owner_id': ownerId,
        'cursor_value': value,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> cursor(String scope, {String ownerId = ''}) async {
    final rows = await (await database).query(
      'sync_cursors',
      columns: ['cursor_value'],
      where: 'scope = ? and owner_id = ?',
      whereArgs: [scope, ownerId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['cursor_value']?.toString();
  }

  Future<String> stageAttachment(Uint8List bytes, String fileName) async {
    final root = await getDatabasesPath();
    final directory = Directory('$root${Platform.pathSeparator}ansar-outbox-files');
    if (!await directory.exists()) await directory.create(recursive: true);
    final safeName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '${directory.path}${Platform.pathSeparator}${newClientActionId()}-$safeName';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<void> deleteStagedFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A stale staged file is removed by the next maintenance pass.
    }
  }

  Future<void> pruneOldData() async {
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 30)).toIso8601String();
    final db = await database;
    await db.delete(
      'offline_rows',
      where: "created_at < ? and local_state is null and scope not in ('branches', 'employees', 'accounts', 'cash_boxes')",
      whereArgs: [cutoff],
    );
  }

  Future<String> integrityStatus() async {
    try {
      final rows = await (await database).rawQuery('pragma quick_check');
      if (rows.isEmpty) return 'unknown';
      return rows.first.values.first?.toString() ?? 'unknown';
    } catch (error) {
      return error.toString();
    }
  }

  String? _timestamp(Object? value) {
    if (value == null) return null;
    final parsed = DateTime.tryParse(value.toString());
    return parsed?.toUtc().toIso8601String() ?? value.toString();
  }
}

class OutboxAction {
  const OutboxAction({
    required this.actionId,
    required this.employeeId,
    required this.actionType,
    required this.payload,
    required this.state,
    required this.attempts,
    required this.createdAt,
    this.entityId,
    this.lastError,
  });

  final String actionId;
  final String employeeId;
  final String actionType;
  final String? entityId;
  final Map<String, dynamic> payload;
  final String state;
  final int attempts;
  final String? lastError;
  final DateTime createdAt;

  factory OutboxAction.fromRow(Map<String, Object?> row) {
    Map<String, dynamic> payload = <String, dynamic>{};
    try {
      final decoded = jsonDecode(row['payload_json']?.toString() ?? '{}');
      if (decoded is Map) payload = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // The action will remain visible as failed instead of crashing the app.
    }
    return OutboxAction(
      actionId: row['action_id']?.toString() ?? '',
      employeeId: row['employee_id']?.toString() ?? '',
      actionType: row['action_type']?.toString() ?? '',
      entityId: row['entity_id']?.toString(),
      payload: payload,
      state: row['state']?.toString() ?? 'pending',
      attempts: (row['attempts'] as num?)?.toInt() ?? 0,
      lastError: row['last_error']?.toString(),
      createdAt: DateTime.tryParse(row['created_at']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
    );
  }
}

String newClientActionId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

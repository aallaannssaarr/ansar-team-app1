import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

class ChatLocalStore {
  ChatLocalStore._();

  static final ChatLocalStore instance = ChatLocalStore._();

  Database? _database;
  Future<Database>? _openingDatabase;

  Future<Database> get database async {
    final current = _database;
    if (current != null && current.isOpen) return current;
    final opening = _openingDatabase;
    if (opening != null) return opening;

    final future = _openDatabase();
    _openingDatabase = future;
    try {
      final opened = await future;
      _database = opened;
      return opened;
    } finally {
      if (identical(_openingDatabase, future)) _openingDatabase = null;
    }
  }

  Future<Database> _openDatabase() async {
    final root = await getDatabasesPath();
    final path = '$root${Platform.pathSeparator}ansar_chat_v2.db';
    return openDatabase(
      path,
      version: 1,
      onConfigure: configureChatDatabase,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE chat_threads (
            employee_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (employee_id, thread_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE chat_messages (
            employee_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            client_message_id TEXT,
            payload TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (employee_id, thread_id, message_id)
          )
        ''');
        await db.execute('''
          CREATE INDEX chat_messages_page_idx
          ON chat_messages (employee_id, thread_id, created_at DESC)
        ''');
        await db.execute('''
          CREATE TABLE chat_drafts (
            employee_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            body TEXT NOT NULL DEFAULT '',
            reply_payload TEXT,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (employee_id, thread_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE chat_outbox (
            client_message_id TEXT PRIMARY KEY,
            employee_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            next_attempt_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX chat_outbox_employee_idx
          ON chat_outbox (employee_id, state, next_attempt_at, created_at)
        ''');
        await db.execute('''
          CREATE TABLE chat_sync_state (
            employee_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            last_event_id INTEGER,
            last_message_at TEXT,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (employee_id, thread_id)
          )
        ''');
      },
    );
  }

  String createClientMessageId(String employeeId) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = Random.secure().nextInt(0x7fffffff).toRadixString(36);
    return '$employeeId-$now-$random';
  }

  Future<String> persistAttachmentBytes(String employeeId, String fileName, Uint8List bytes) async {
    final root = await getDatabasesPath();
    final folder = Directory('$root${Platform.pathSeparator}ansar_chat_outbox${Platform.pathSeparator}$employeeId');
    if (!await folder.exists()) await folder.create(recursive: true);
    final safeName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '${folder.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}-$safeName';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<List<Map<String, dynamic>>> readThreads(String employeeId) async {
    final db = await database;
    final rows = await db.query(
      'chat_threads',
      columns: ['payload'],
      where: 'employee_id = ?',
      whereArgs: [employeeId],
      orderBy: 'updated_at DESC',
    );
    return rows.map((row) => _decodeMap(row['payload'])).whereType<Map<String, dynamic>>().toList();
  }

  Future<void> writeThreads(String employeeId, List<Map<String, dynamic>> threads) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final thread in threads) {
      final id = thread['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final payload = encodeChatCachePayload(thread);
      if (payload == null) continue;
      final updated = DateTime.tryParse(thread['updated_at']?.toString() ?? '')?.millisecondsSinceEpoch ?? now;
      batch.insert(
        'chat_threads',
        {
          'employee_id': employeeId,
          'thread_id': id,
          'payload': payload,
          'updated_at': updated,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> readMessages(
    String employeeId,
    String threadId, {
    int limit = 120,
  }) async {
    final db = await database;
    final rows = await db.query(
      'chat_messages',
      columns: ['payload'],
      where: 'employee_id = ? AND thread_id = ?',
      whereArgs: [employeeId, threadId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    final decoded = rows.map((row) => _decodeMap(row['payload'])).whereType<Map<String, dynamic>>().toList();
    return decoded.reversed.toList();
  }

  Future<void> writeMessages(
    String employeeId,
    String threadId,
    Iterable<Map<String, dynamic>> messages,
  ) async {
    final db = await database;
    await db.transaction((transaction) async {
      final batch = transaction.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final message in messages) {
        final id = message['id']?.toString() ?? message['client_message_id']?.toString();
        if (id == null || id.isEmpty) continue;
        final payload = encodeChatCachePayload(message);
        if (payload == null) continue;
        final created = DateTime.tryParse(message['created_at']?.toString() ?? '')?.millisecondsSinceEpoch ?? now;
        batch.insert(
          'chat_messages',
          {
            'employee_id': employeeId,
            'thread_id': threadId,
            'message_id': id,
            'client_message_id': message['client_message_id']?.toString(),
            'payload': payload,
            'created_at': created,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      await transaction.rawDelete(
        '''
          DELETE FROM chat_messages
          WHERE employee_id = ? AND thread_id = ? AND message_id NOT IN (
            SELECT message_id FROM chat_messages
            WHERE employee_id = ? AND thread_id = ?
            ORDER BY created_at DESC LIMIT 500
          )
        ''',
        [employeeId, threadId, employeeId, threadId],
      );
      final ninetyDaysAgo = DateTime.now().subtract(const Duration(days: 90)).millisecondsSinceEpoch;
      await transaction.delete('chat_messages', where: 'updated_at < ?', whereArgs: [ninetyDaysAgo]);
    });
  }

  Future<String> readDraft(String employeeId, String threadId) async {
    final db = await database;
    final rows = await db.query(
      'chat_drafts',
      columns: ['body'],
      where: 'employee_id = ? AND thread_id = ?',
      whereArgs: [employeeId, threadId],
      limit: 1,
    );
    return rows.isEmpty ? '' : rows.first['body']?.toString() ?? '';
  }

  Future<Map<String, String>> readDrafts(String employeeId) async {
    final db = await database;
    final rows = await db.query(
      'chat_drafts',
      columns: ['thread_id', 'body'],
      where: 'employee_id = ?',
      whereArgs: [employeeId],
    );
    return {
      for (final row in rows)
        if ((row['body']?.toString() ?? '').trim().isNotEmpty)
          row['thread_id']!.toString(): row['body']!.toString(),
    };
  }

  Future<Map<String, Map<String, dynamic>>> readLatestMessagesByThread(String employeeId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
        SELECT message.thread_id, message.payload
        FROM chat_messages message
        INNER JOIN (
          SELECT thread_id, MAX(created_at) AS latest_created_at
          FROM chat_messages
          WHERE employee_id = ?
          GROUP BY thread_id
        ) latest
          ON latest.thread_id = message.thread_id
         AND latest.latest_created_at = message.created_at
        WHERE message.employee_id = ?
      ''',
      [employeeId, employeeId],
    );
    final result = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final threadId = row['thread_id']?.toString();
      final payload = _decodeMap(row['payload']);
      if (threadId != null && payload != null) result[threadId] = payload;
    }
    return result;
  }

  Future<void> writeDraft(String employeeId, String threadId, String body) async {
    final db = await database;
    if (body.trim().isEmpty) {
      await db.delete(
        'chat_drafts',
        where: 'employee_id = ? AND thread_id = ?',
        whereArgs: [employeeId, threadId],
      );
      return;
    }
    await db.insert(
      'chat_drafts',
      {
        'employee_id': employeeId,
        'thread_id': threadId,
        'body': body,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> enqueue({
    required String clientMessageId,
    required String employeeId,
    required String threadId,
    required String operation,
    required Map<String, dynamic> payload,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'chat_outbox',
      {
        'client_message_id': clientMessageId,
        'employee_id': employeeId,
        'thread_id': threadId,
        'operation': operation,
        'payload': jsonEncode(payload),
        'state': 'pending',
        'attempts': 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, dynamic>>> pendingOutbox(String employeeId, {int limit = 30}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(
      'chat_outbox',
      where: "employee_id = ? AND state IN ('pending', 'failed') AND (next_attempt_at IS NULL OR next_attempt_at <= ?)",
      whereArgs: [employeeId, now],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map((row) {
      final payload = _decodeMap(row['payload']) ?? <String, dynamic>{};
      return {...row, 'payload': payload};
    }).toList();
  }

  Future<void> markOutboxSending(String clientMessageId) async {
    final db = await database;
    await db.update(
      'chat_outbox',
      {'state': 'sending', 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'client_message_id = ?',
      whereArgs: [clientMessageId],
    );
  }

  Future<void> updateLocalMessageState(
    String employeeId,
    String threadId,
    String clientMessageId,
    String state, {
    String? error,
  }) async {
    final db = await database;
    final rows = await db.query(
      'chat_messages',
      columns: ['message_id', 'payload'],
      where: 'employee_id = ? AND thread_id = ? AND client_message_id = ?',
      whereArgs: [employeeId, threadId, clientMessageId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final payload = _decodeMap(rows.first['payload']);
    if (payload == null) return;
    payload['local_state'] = state;
    if (error == null) {
      payload.remove('local_error');
    } else {
      payload['local_error'] = error;
    }
    await db.update(
      'chat_messages',
      {'payload': jsonEncode(payload), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'employee_id = ? AND thread_id = ? AND message_id = ?',
      whereArgs: [employeeId, threadId, rows.first['message_id']],
    );
  }

  Future<void> markOutboxFailed(String clientMessageId, Object error, int attempts) async {
    final db = await database;
    final delaySeconds = min(300, 2 << min(attempts, 7));
    final now = DateTime.now();
    await db.update(
      'chat_outbox',
      {
        'state': 'failed',
        'attempts': attempts,
        'last_error': error.toString(),
        'next_attempt_at': now.add(Duration(seconds: delaySeconds)).millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      },
      where: 'client_message_id = ?',
      whereArgs: [clientMessageId],
    );
  }

  Future<void> removeOutbox(String clientMessageId) async {
    final db = await database;
    await db.delete('chat_outbox', where: 'client_message_id = ?', whereArgs: [clientMessageId]);
  }

  Future<void> retryOutbox(String clientMessageId) async {
    final db = await database;
    await db.update(
      'chat_outbox',
      {'state': 'pending', 'next_attempt_at': null, 'last_error': null},
      where: 'client_message_id = ?',
      whereArgs: [clientMessageId],
    );
  }

  Future<int> lastEventId(String employeeId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MAX(last_event_id) AS value FROM chat_sync_state WHERE employee_id = ?',
      [employeeId],
    );
    return result.isEmpty ? 0 : (result.first['value'] as num?)?.toInt() ?? 0;
  }

  Future<void> saveLastEventId(String employeeId, int eventId) async {
    final db = await database;
    await db.insert(
      'chat_sync_state',
      {
        'employee_id': employeeId,
        'thread_id': '*',
        'last_event_id': eventId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Map<String, dynamic>? _decodeMap(Object? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw.toString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}

String? encodeChatCachePayload(Map<String, dynamic> value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return null;
  }
}

Future<void> configureChatDatabase(Database db) async {
  await db.execute('PRAGMA foreign_keys = ON');
  try {
    // journal_mode returns a row, so Android requires the query API here.
    await db.rawQuery('PRAGMA journal_mode = WAL');
  } on DatabaseException {
    // WAL is an optimization; the chat cache remains valid with the platform mode.
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_database.dart';
import 'product_cache.dart';

enum SyncHealth { idle, syncing, offline, attention }

class SyncSnapshot {
  const SyncSnapshot({
    required this.health,
    required this.pending,
    this.lastSuccessAt,
    this.message,
  });

  final SyncHealth health;
  final int pending;
  final DateTime? lastSuccessAt;
  final String? message;

  SyncSnapshot copyWith({
    SyncHealth? health,
    int? pending,
    DateTime? lastSuccessAt,
    String? message,
    bool clearMessage = false,
  }) {
    return SyncSnapshot(
      health: health ?? this.health,
      pending: pending ?? this.pending,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}

class SyncCoordinator {
  SyncCoordinator._();

  static final SyncCoordinator instance = SyncCoordinator._();

  final ValueNotifier<SyncSnapshot> status = ValueNotifier<SyncSnapshot>(
    const SyncSnapshot(health: SyncHealth.idle, pending: 0),
  );

  SupabaseClient? _client;
  String? _employeeId;
  int _branchNum = 0;
  bool _isAdmin = false;
  Timer? _timer;
  Future<void>? _running;
  DateTime? _lastQueriesPullAt;

  Future<void> start({
    required SupabaseClient client,
    required String employeeId,
    required int branchNum,
    required bool isAdmin,
  }) async {
    _client = client;
    _employeeId = employeeId;
    _branchNum = branchNum;
    _isAdmin = isAdmin;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => unawaited(synchronize()));
    await OfflineDatabase.instance.recoverInterruptedActions(employeeId);
    await refreshPendingCount();
    unawaited(synchronize());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _employeeId = null;
    _branchNum = 0;
    _isAdmin = false;
  }

  Future<void> refreshPendingCount() async {
    final employeeId = _employeeId;
    if (employeeId == null) return;
    final pending = await OfflineDatabase.instance.pendingActionCount(employeeId);
    status.value = status.value.copyWith(pending: pending);
  }

  Future<void> synchronize({bool forceCatalog = false}) {
    final current = _running;
    if (current != null) return current;
    final future = _synchronize(forceCatalog: forceCatalog);
    _running = future;
    return future.whenComplete(() => _running = null);
  }

  Future<void> _synchronize({required bool forceCatalog}) async {
    final client = _client;
    final employeeId = _employeeId;
    if (client == null || employeeId == null) return;
    status.value = status.value.copyWith(health: SyncHealth.syncing, clearMessage: true);
    try {
      await pullServerData(client, employeeId);
      await flushOutbox(client, employeeId);
      await pullServerData(client, employeeId);
      await ProductSearchCache.instance.synchronize(client, force: forceCatalog);
      await OfflineDatabase.instance.pruneOldData();
      final pending = await OfflineDatabase.instance.pendingActionCount(employeeId);
      status.value = SyncSnapshot(
        health: pending == 0 ? SyncHealth.idle : SyncHealth.attention,
        pending: pending,
        lastSuccessAt: DateTime.now(),
        message: pending == 0 ? null : 'توجد $pending عمليات بانتظار المزامنة',
      );
    } catch (error) {
      final pending = await OfflineDatabase.instance.pendingActionCount(employeeId);
      status.value = SyncSnapshot(
        health: _isNetworkFailure(error) ? SyncHealth.offline : SyncHealth.attention,
        pending: pending,
        lastSuccessAt: status.value.lastSuccessAt,
        message: _friendlySyncError(error),
      );
    }
  }

  Future<void> pullServerData(SupabaseClient client, String employeeId) async {
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 30)).toIso8601String();
    // Unlike the individual legacy scopes, this probe is allowed to fail so
    // the UI can accurately report offline state instead of a false success.
    await client.from('ansar_employees').select('id').limit(1);
    await _pullBranches(client);
    await _pullEmployees(client);
    await _pullAttendance(client, cutoff);
    await _pullTransfers(client, employeeId, cutoff);
    await _pullChat(client, employeeId, cutoff);
    await _pullNotifications(client, employeeId, cutoff);
    await _pullQueries(client, cutoff);
  }

  Future<void> _pullBranches(SupabaseClient client) async {
    try {
      final rows = await client.from('ansar_branches').select().order('sto_num');
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'branches',
        rows: rows.cast<Map<String, dynamic>>(),
        idOf: (row) => '${row['sto_num']}',
      );
    } catch (_) {
      // Each scope is independent so one legacy table cannot stop the whole pull.
    }
  }

  Future<void> _pullEmployees(SupabaseClient client) async {
    try {
      final rows = await client
          .from('ansar_employees')
          .select('id, display_name, full_name, branch_num, role, is_active, avatar_url, phone, email, job_title, updated_at, last_seen_at');
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'employees',
        rows: _safeEmployeeRows(rows.cast<Map<String, dynamic>>()),
        idOf: (row) => '${row['id']}',
      );
    } catch (_) {
      try {
        final rows = await client.from('ansar_employees').select();
        await OfflineDatabase.instance.replaceServerRows(
          scope: 'employees',
          rows: _safeEmployeeRows(rows.cast<Map<String, dynamic>>()),
          idOf: (row) => '${row['id']}',
        );
      } catch (_) {}
    }
  }

  Future<void> _pullAttendance(SupabaseClient client, String cutoff) async {
    try {
      final rows = await client
          .from('ansar_attendance_logs')
          .select()
          .gte('check_in_at', cutoff)
          .order('check_in_at', ascending: false)
          .limit(2000);
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'attendance',
        rows: rows.cast<Map<String, dynamic>>(),
        idOf: (row) => '${row['id']}',
      );
    } catch (_) {}
  }

  Future<void> _pullTransfers(SupabaseClient client, String employeeId, String cutoff) async {
    try {
      final orderRows = await client
          .from('ansar_transfer_orders')
          .select()
          .gte('created_at', cutoff)
          .order('created_at', ascending: false)
          .limit(500);
      final visible = orderRows.cast<Map<String, dynamic>>().where((row) {
        if (_isAdmin) return true;
        return _int(row['from_branch_num']) == _branchNum || _int(row['to_branch_num']) == _branchNum;
      }).toList();
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'transfer_orders',
        ownerId: employeeId,
        rows: visible,
        idOf: (row) => '${row['id']}',
      );
      final ids = visible.map((row) => row['id']).whereType<Object>().toList();
      if (ids.isEmpty) return;
      final items = await client.from('ansar_transfer_order_items').select().inFilter('order_id', ids);
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'transfer_items',
        ownerId: employeeId,
        rows: items.cast<Map<String, dynamic>>(),
        idOf: (row) => '${row['id']}',
      );
      try {
        final events = await client.from('ansar_order_events').select().inFilter('order_id', ids);
        await OfflineDatabase.instance.replaceServerRows(
          scope: 'transfer_events',
          ownerId: employeeId,
          rows: events.cast<Map<String, dynamic>>(),
          idOf: (row) => '${row['id']}',
        );
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _pullChat(SupabaseClient client, String employeeId, String cutoff) async {
    try {
      final participants = await client
          .from('ansar_chat_participants')
          .select()
          .eq('employee_id', employeeId);
      final participantRows = participants.cast<Map<String, dynamic>>();
      final participantIds = participantRows.map((row) => '${row['thread_id']}').toSet();
      final threadRows = await client
          .from('ansar_chat_threads')
          .select()
          .order('updated_at', ascending: false)
          .limit(300);
      final visibleThreads = threadRows.cast<Map<String, dynamic>>().where((row) {
        return row['thread_type'] == 'general' || participantIds.contains('${row['id']}');
      }).toList();
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'chat_participants',
        ownerId: employeeId,
        rows: participantRows,
        idOf: (row) => '${row['thread_id']}',
      );
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'chat_threads',
        ownerId: employeeId,
        rows: visibleThreads,
        idOf: (row) => '${row['id']}',
      );
      final threadIds = visibleThreads.map((row) => row['id']).whereType<Object>().toList();
      if (threadIds.isEmpty) return;
      try {
        final allParticipants = await client
            .from('ansar_chat_participants')
            .select()
            .inFilter('thread_id', threadIds);
        await OfflineDatabase.instance.replaceServerRows(
          scope: 'chat_participants_all',
          ownerId: employeeId,
          rows: allParticipants.cast<Map<String, dynamic>>(),
          idOf: (row) => '${row['thread_id']}:${row['employee_id']}',
        );
      } catch (_) {}
      final messages = await client
          .from('ansar_chat_messages')
          .select()
          .inFilter('thread_id', threadIds)
          .gte('created_at', cutoff)
          .order('created_at', ascending: true)
          .limit(5000);
      final messageRows = messages.cast<Map<String, dynamic>>();
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'chat_messages',
        ownerId: employeeId,
        rows: messageRows,
        idOf: (row) => '${row['client_action_id'] ?? row['id']}',
      );
      final messageIds = messageRows.map((row) => row['id']).whereType<Object>().toList();
      if (messageIds.isNotEmpty) {
        try {
          final receipts = await client
              .from('ansar_chat_message_receipts')
              .select()
              .inFilter('message_id', messageIds);
          await OfflineDatabase.instance.replaceServerRows(
            scope: 'chat_receipts',
            ownerId: employeeId,
            rows: receipts.cast<Map<String, dynamic>>(),
            idOf: (row) => '${row['message_id']}:${row['employee_id']}',
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _pullNotifications(SupabaseClient client, String employeeId, String cutoff) async {
    try {
      final rows = await client
          .from('ansar_notification_queue')
          .select()
          .gte('created_at', cutoff)
          .order('created_at', ascending: false)
          .limit(1000);
      final visible = rows.cast<Map<String, dynamic>>().where((row) {
        final targetEmployee = row['employee_id']?.toString();
        final targetBranch = _int(row['branch_num']);
        return (targetEmployee == null || targetEmployee.isEmpty || targetEmployee == employeeId) &&
            (targetBranch == null || targetBranch == _branchNum || _isAdmin);
      }).toList();
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'notifications',
        ownerId: employeeId,
        rows: visible,
        idOf: (row) => '${row['id']}',
      );
    } catch (_) {}
  }

  Future<void> _pullQueries(SupabaseClient client, String cutoff) async {
    final now = DateTime.now().toUtc();
    if (_lastQueriesPullAt != null && now.difference(_lastQueriesPullAt!) < const Duration(minutes: 5)) {
      return;
    }
    var recentBills = <Map<String, dynamic>>[];
    try {
      final accounts = await client.from('accounts').select('num, name, ras, owner').order('num');
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'accounts',
        rows: accounts.cast<Map<String, dynamic>>(),
        idOf: (row) => '${row['num']}',
      );
    } catch (_) {}
    try {
      final cutoffDate = cutoff.substring(0, 10);
      final bills = await client
          .from('bills_full')
          .select('book, bnum, date, accnum, totalvalue, remark, kind')
          .gte('date', cutoffDate)
          .order('date', ascending: false)
          .limit(3000);
      recentBills = bills.cast<Map<String, dynamic>>();
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'sales',
        rows: recentBills,
        idOf: (row) => '${row['book']}:${row['bnum']}:${row['date']}',
      );
    } catch (_) {}
    if (recentBills.isNotEmpty) {
      try {
        final items = <Map<String, dynamic>>[];
        final byBook = <int, Set<int>>{};
        for (final bill in recentBills.take(800)) {
          final book = _int(bill['book']);
          final billNumber = _int(bill['bnum']);
          if (book != null && billNumber != null) {
            byBook.putIfAbsent(book, () => <int>{}).add(billNumber);
          }
        }
        for (final entry in byBook.entries) {
          final numbers = entry.value.toList();
          for (var offset = 0; offset < numbers.length; offset += 80) {
            final end = offset + 80 < numbers.length ? offset + 80 : numbers.length;
            final page = await client
                .from('bill_items_full')
                .select('book, bnum, kind, item, matnum, quantity, price, value, remarki')
                .eq('book', entry.key)
                .eq('kind', 0)
                .inFilter('bnum', numbers.sublist(offset, end))
                .order('item');
            items.addAll(page.cast<Map<String, dynamic>>());
          }
        }
        await OfflineDatabase.instance.replaceServerRows(
          scope: 'sales_items',
          rows: items,
          idOf: (row) => '${row['book']}:${row['bnum']}:${row['kind']}:${row['item']}',
        );
      } catch (_) {}
    }
    try {
      final cutoffDate = cutoff.substring(0, 10);
      final entries = await client
          .from('account_entries')
          .select('num, item, kind, date, remark, acc_num, acc_num2, cash, billnum')
          .gte('date', cutoffDate)
          .order('date', ascending: false)
          .limit(5000);
      await OfflineDatabase.instance.replaceServerRows(
        scope: 'account_entries',
        rows: entries.cast<Map<String, dynamic>>(),
        idOf: (row) => '${row['num']}:${row['item']}:${row['date']}',
      );
    } catch (_) {}
    _lastQueriesPullAt = now;
  }

  Future<void> flushOutbox(SupabaseClient client, String employeeId) async {
    var flushedAny = false;
    try {
      while (true) {
        final actions = await OfflineDatabase.instance.dueActions(employeeId);
        if (actions.isEmpty) break;
        for (final action in actions) {
          await OfflineDatabase.instance.markActionSending(action.actionId);
          try {
            final payload = await _prepareAttachments(client, action);
            final serverPayload = _serverPayload(payload);
            try {
              await client.rpc('ansar_apply_offline_action', params: {
                'p_action_id': action.actionId,
                'p_employee_id': employeeId,
                'p_action_type': action.actionType,
                'p_payload': serverPayload,
              });
            } catch (error) {
              if (!_missingSyncFunction(error)) rethrow;
              await _applyLegacy(client, action, serverPayload);
            }
            await _removeLocalPlaceholders(action);
            await OfflineDatabase.instance.completeAction(action.actionId);
            flushedAny = true;
          } catch (error) {
            await OfflineDatabase.instance.failAction(
              action,
              error,
              conflict: _isConflict(error),
            );
            if (_isNetworkFailure(error)) rethrow;
            // Preserve creation/update order. A later action can depend on the
            // server id produced by the failed action in front of it.
            return;
          }
        }
      }
    } finally {
      if (flushedAny) {
        try {
          await client.functions.invoke('send-notifications', body: {'source': 'offline-sync'});
        } catch (_) {
          // The scheduled sender will process queued notifications later.
        }
      }
    }
  }

  Future<Map<String, dynamic>> _prepareAttachments(SupabaseClient client, OutboxAction action) async {
    if (action.actionType != 'chat_send') return action.payload;
    final attachments = (action.payload['attachments'] as List?)?.whereType<Map>().toList() ?? const [];
    if (attachments.isEmpty || attachments.every((item) => item['path'] != null)) return action.payload;
    final uploaded = <Map<String, dynamic>>[];
    for (var index = 0; index < attachments.length; index++) {
      final item = Map<String, dynamic>.from(attachments[index]);
      if (item['path'] != null) {
        uploaded.add(item);
        continue;
      }
      final localPath = item['local_path']?.toString();
      if (localPath == null || !await File(localPath).exists()) {
        throw StateError('تعذر العثور على المرفق المحفوظ في الهاتف');
      }
      final safeName = (item['name']?.toString() ?? 'file').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final remotePath = '${action.payload['thread_id']}/${action.actionId}-$index-$safeName';
      final bytes = await File(localPath).readAsBytes();
      await client.storage.from('ansar-chat').uploadBinary(
            remotePath,
            bytes,
            fileOptions: FileOptions(
              contentType: item['mime_type']?.toString(),
              upsert: true,
            ),
          );
      uploaded.add({
        'path': remotePath,
        'name': item['name'],
        'size': item['size'] ?? bytes.length,
        'mime_type': item['mime_type'],
        'local_path': localPath,
      });
    }
    final payload = {...action.payload, 'attachments': uploaded};
    await OfflineDatabase.instance.updateActionPayload(action.actionId, payload);
    return payload;
  }

  Map<String, dynamic> _serverPayload(Map<String, dynamic> payload) {
    final attachments = (payload['attachments'] as List?)?.whereType<Map>().map((item) {
      return Map<String, dynamic>.from(item)..remove('local_path');
    }).toList();
    return {
      ...payload,
      if (attachments != null) 'attachments': attachments,
    };
  }

  Future<void> _applyLegacy(
    SupabaseClient client,
    OutboxAction action,
    Map<String, dynamic> payload,
  ) async {
    switch (action.actionType) {
      case 'chat_send':
        final values = <String, dynamic>{
          'thread_id': payload['thread_id'],
          'sender_id': action.employeeId,
          'body': payload['body'] ?? '',
          'message_type': payload['message_type'] ?? 'text',
          if (payload['attachments'] is List) 'attachments': payload['attachments'],
          if (payload['reply_to_id'] != null) 'reply_to_id': payload['reply_to_id'],
          if (payload['transfer_order_id'] != null) 'transfer_order_id': payload['transfer_order_id'],
        };
        try {
          await client.from('ansar_chat_messages').insert({...values, 'client_action_id': action.actionId});
        } catch (_) {
          await client.from('ansar_chat_messages').insert(values);
        }
        await client.from('ansar_chat_threads').update({
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', payload['thread_id']);
        return;
      case 'attendance_check_in':
        final values = Map<String, dynamic>.from(payload['values'] as Map? ?? payload);
        try {
          await client.from('ansar_attendance_logs').insert({...values, 'client_action_id': action.actionId});
        } catch (_) {
          final legacyValues = Map<String, dynamic>.from(values)..remove('client_action_id');
          await client.from('ansar_attendance_logs').insert(legacyValues);
        }
        return;
      case 'attendance_check_out':
        final values = Map<String, dynamic>.from(payload['values'] as Map? ?? const {});
        await client.from('ansar_attendance_logs').update(values).eq('id', payload['log_id']);
        return;
      case 'transfer_create':
        final order = Map<String, dynamic>.from(payload['order'] as Map? ?? const {});
        dynamic inserted;
        try {
          inserted = await client
              .from('ansar_transfer_orders')
              .insert({...order, 'client_action_id': action.actionId})
              .select('id')
              .single();
        } catch (_) {
          final legacyOrder = Map<String, dynamic>.from(order)..remove('client_action_id');
          inserted = await client.from('ansar_transfer_orders').insert(legacyOrder).select('id').single();
        }
        final items = (payload['items'] as List? ?? const []).whereType<Map>().map((item) {
          return {...Map<String, dynamic>.from(item), 'order_id': inserted['id']};
        }).toList();
        if (items.isNotEmpty) {
          try {
            await client.from('ansar_transfer_order_items').insert(items);
          } catch (_) {
            final legacyItems = items
                .map((item) => Map<String, dynamic>.from(item)..remove('client_action_id'))
                .toList();
            await client.from('ansar_transfer_order_items').insert(legacyItems);
          }
        }
        return;
      case 'transfer_status':
        await client.from('ansar_transfer_orders').update({
          'status': payload['status'],
          'handled_by': action.employeeId,
        }).eq('id', payload['order_id']);
        return;
      case 'transfer_item':
        await client.from('ansar_transfer_order_items').update({
          'item_status': payload['item_status'],
          'approved_quantity': payload['approved_quantity'],
        }).eq('id', payload['item_id']);
        return;
      case 'transfer_receipt':
        await client.rpc('ansar_confirm_transfer_receipt', params: {
          'p_order_id': '${payload['order_id']}',
          'p_employee_id': action.employeeId,
          'p_items': payload['items'],
          'p_note': payload['note'],
        });
        return;
      default:
        throw UnsupportedError('نوع العملية غير مدعوم: ${action.actionType}');
    }
  }

  Future<void> _removeLocalPlaceholders(OutboxAction action) async {
    switch (action.actionType) {
      case 'chat_send':
        await OfflineDatabase.instance.removeRow(
          'chat_messages',
          action.actionId,
          ownerId: action.employeeId,
        );
        for (final attachment in (action.payload['attachments'] as List? ?? const []).whereType<Map>()) {
          await OfflineDatabase.instance.deleteStagedFile(attachment['local_path']?.toString());
        }
        break;
      case 'attendance_check_in':
        await OfflineDatabase.instance.removeRow('attendance', action.actionId);
        break;
      case 'attendance_check_out':
        await OfflineDatabase.instance.removeRow(
          'attendance',
          '${action.payload['local_row_id'] ?? action.entityId ?? action.actionId}',
        );
        break;
      case 'transfer_create':
        await OfflineDatabase.instance.removeRow(
          'transfer_orders',
          action.actionId,
          ownerId: action.employeeId,
        );
        await OfflineDatabase.instance.removeLocalRowsWhere(
          'transfer_items',
          ownerId: action.employeeId,
          test: (row) => '${row['order_id']}' == action.actionId,
        );
        break;
      case 'transfer_status':
      case 'transfer_receipt':
        await OfflineDatabase.instance.removeRow(
          'transfer_orders',
          '${action.payload['local_row_id'] ?? action.entityId ?? action.actionId}',
          ownerId: action.employeeId,
        );
        break;
      case 'transfer_item':
        await OfflineDatabase.instance.removeRow(
          'transfer_items',
          '${action.payload['local_row_id'] ?? action.entityId ?? action.actionId}',
          ownerId: action.employeeId,
        );
        break;
    }
  }

  bool _missingSyncFunction(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('pgrst202') ||
        text.contains('could not find the function') ||
        text.contains('ansar_apply_offline_action') && text.contains('not found');
  }

  bool _isConflict(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('sync_conflict') ||
        text.contains('تعارض') ||
        text.contains('يتداخل') ||
        text.contains('انتقال حالة') ||
        text.contains('قبل بدء التوصيل');
  }

  bool _isNetworkFailure(Object error) {
    final text = error.toString().toLowerCase();
    return error is SocketException ||
        text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('network is unreachable') ||
        text.contains('connection reset') ||
        text.contains('clientexception') ||
        text.contains('timed out');
  }

  String _friendlySyncError(Object error) {
    if (_isNetworkFailure(error)) return 'لا يوجد اتصال. ستتم المزامنة تلقائياً عند عودة الإنترنت.';
    final text = error.toString();
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }

  int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  List<Map<String, dynamic>> _safeEmployeeRows(List<Map<String, dynamic>> rows) {
    return rows.map((row) {
      return Map<String, dynamic>.from(row)
        ..remove('username')
        ..remove('password')
        ..remove('password_hash')
        ..remove('password_digest')
        ..remove('pin')
        ..remove('secret');
    }).toList();
  }
}

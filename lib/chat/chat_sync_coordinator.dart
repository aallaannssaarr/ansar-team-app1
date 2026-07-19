import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_local_store.dart';

enum ChatSyncEventType { connected, disconnected, threadChanged, messageSent, messageFailed }

class ChatSyncEvent {
  const ChatSyncEvent(this.type, {this.threadId, this.clientMessageId, this.payload, this.error});

  final ChatSyncEventType type;
  final String? threadId;
  final String? clientMessageId;
  final Map<String, dynamic>? payload;
  final Object? error;
}

class ChatSyncCoordinator {
  ChatSyncCoordinator({required this.client, ChatLocalStore? store}) : store = store ?? ChatLocalStore.instance;

  final SupabaseClient client;
  final ChatLocalStore store;
  final StreamController<ChatSyncEvent> _events = StreamController<ChatSyncEvent>.broadcast();

  Stream<ChatSyncEvent> get events => _events.stream;

  String? _employeeId;
  RealtimeChannel? _inboxChannel;
  RealtimeChannel? _messageChangesChannel;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _retryTimer;
  bool _flushing = false;
  bool _online = true;
  bool _inboxConnected = false;
  bool _messageChangesConnected = false;

  Future<void> start(String employeeId) async {
    if (_employeeId == employeeId && _inboxChannel != null) return;
    await stop();
    _employeeId = employeeId;
    await store.database;
    final connectivity = await Connectivity().checkConnectivity();
    _online = connectivity.any((result) => result != ConnectivityResult.none);
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      final connected = results.any((result) => result != ConnectivityResult.none);
      if (_online != connected) {
        _online = connected;
        _events.add(ChatSyncEvent(connected ? ChatSyncEventType.connected : ChatSyncEventType.disconnected));
      }
      if (connected) unawaited(flushOutbox());
    });
    _subscribeInbox();
    _subscribeMessageChanges();
    _retryTimer = Timer.periodic(const Duration(seconds: 20), (_) => unawaited(_retryPendingWork()));
    if (_online) unawaited(flushOutbox());
  }

  void _subscribeInbox() {
    final employeeId = _employeeId;
    if (employeeId == null) return;
    final old = _inboxChannel;
    if (old != null) unawaited(client.removeChannel(old));
    _inboxChannel = client.channel('ansar-chat-v2-inbox-$employeeId-${DateTime.now().millisecondsSinceEpoch}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'ansar_chat_inbox_events',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'employee_id',
          value: employeeId,
        ),
        callback: (payload) {
          final row = payload.newRecord;
          final threadId = row['thread_id']?.toString();
          if (threadId != null && threadId.isNotEmpty) {
            _events.add(ChatSyncEvent(ChatSyncEventType.threadChanged, threadId: threadId, payload: row));
          }
          final id = (row['id'] as num?)?.toInt();
          if (id != null) unawaited(store.saveLastEventId(employeeId, id));
        },
      )
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _inboxConnected = true;
          _events.add(const ChatSyncEvent(ChatSyncEventType.connected));
          unawaited(_recoverMissedEvents());
        } else if (status == RealtimeSubscribeStatus.channelError || status == RealtimeSubscribeStatus.timedOut) {
          _inboxConnected = false;
          if (!_messageChangesConnected) {
            _events.add(ChatSyncEvent(ChatSyncEventType.disconnected, error: error));
          }
          Future<void>.delayed(const Duration(seconds: 15), () {
            if (_employeeId == employeeId) _subscribeInbox();
          });
        }
      });
  }

  void _subscribeMessageChanges() {
    final employeeId = _employeeId;
    if (employeeId == null) return;
    final old = _messageChangesChannel;
    if (old != null) unawaited(client.removeChannel(old));
    _messageChangesChannel = client.channel(
      'ansar-chat-message-changes-$employeeId-${DateTime.now().millisecondsSinceEpoch}',
    )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_chat_messages',
        callback: (payload) {
          final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
          final threadId = row['thread_id']?.toString();
          if (threadId == null || threadId.isEmpty) return;
          _events.add(
            ChatSyncEvent(
              ChatSyncEventType.threadChanged,
              threadId: threadId,
              payload: Map<String, dynamic>.from(row),
            ),
          );
        },
      )
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _messageChangesConnected = true;
          _events.add(const ChatSyncEvent(ChatSyncEventType.connected));
        } else if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          _messageChangesConnected = false;
          if (!_inboxConnected) {
            _events.add(ChatSyncEvent(ChatSyncEventType.disconnected, error: error));
          }
          Future<void>.delayed(const Duration(seconds: 5), () {
            if (_employeeId == employeeId) _subscribeMessageChanges();
          });
        }
      });
  }

  Future<void> _recoverMissedEvents() async {
    final employeeId = _employeeId;
    if (employeeId == null || !_online) return;
    try {
      final lastId = await store.lastEventId(employeeId);
      final rows = await client
          .from('ansar_chat_inbox_events')
          .select()
          .eq('employee_id', employeeId)
          .gt('id', lastId)
          .order('id')
          .limit(250);
      var newest = lastId;
      final changedThreads = <String>{};
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        final id = (row['id'] as num?)?.toInt() ?? 0;
        if (id > newest) newest = id;
        final threadId = row['thread_id']?.toString();
        if (threadId != null && threadId.isNotEmpty) changedThreads.add(threadId);
      }
      if (newest > lastId) await store.saveLastEventId(employeeId, newest);
      for (final threadId in changedThreads) {
        _events.add(ChatSyncEvent(ChatSyncEventType.threadChanged, threadId: threadId));
      }
    } catch (_) {
      // The app can keep showing its local snapshot until the next reconnect.
    }
  }

  Future<Map<String, dynamic>> enqueueMessage({
    required String employeeId,
    required String threadId,
    required String body,
    String messageType = 'text',
    List<Map<String, dynamic>> attachments = const [],
    String? replyToId,
    String? forwardedFromId,
    List<String> mentions = const [],
    bool requiresAck = false,
    Map<String, dynamic>? poll,
  }) async {
    final clientMessageId = store.createClientMessageId(employeeId);
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = <String, dynamic>{
      'employee_id': employeeId,
      'thread_id': threadId,
      'body': body,
      'message_type': messageType,
      'attachments': attachments,
      'reply_to_id': replyToId,
      'forwarded_from_id': forwardedFromId,
      'mentions': mentions,
      'requires_ack': requiresAck,
      'poll': poll,
    };
    final optimistic = <String, dynamic>{
      'id': clientMessageId,
      'client_message_id': clientMessageId,
      'thread_id': threadId,
      'sender_id': employeeId,
      'body': body,
      'message_type': messageType,
      'attachments': attachments,
      'reply_to_id': replyToId,
      'forwarded_from_id': forwardedFromId,
      'mentions': mentions,
      'requires_ack': requiresAck,
      'created_at': now,
      'local_state': _online ? 'sending' : 'pending',
    };
    final cached = await store.readMessages(employeeId, threadId, limit: 500);
    await store.writeMessages(employeeId, threadId, [...cached, optimistic]);
    await store.enqueue(
      clientMessageId: clientMessageId,
      employeeId: employeeId,
      threadId: threadId,
      operation: 'send',
      payload: payload,
    );
    _events.add(ChatSyncEvent(ChatSyncEventType.threadChanged, threadId: threadId, payload: optimistic));
    if (_online) unawaited(flushOutbox());
    return optimistic;
  }

  Future<void> flushOutbox() async {
    final employeeId = _employeeId;
    if (employeeId == null || !_online || _flushing) return;
    _flushing = true;
    try {
      final pending = await store.pendingOutbox(employeeId);
      for (final item in pending) {
        if (_employeeId != employeeId || !_online) break;
        final clientMessageId = item['client_message_id']?.toString() ?? '';
        final attempts = (item['attempts'] as num?)?.toInt() ?? 0;
        final payload = Map<String, dynamic>.from(item['payload'] as Map);
        try {
          await store.markOutboxSending(clientMessageId);
          await store.updateLocalMessageState(
            employeeId,
            item['thread_id']?.toString() ?? '',
            clientMessageId,
            'sending',
          );
          final originalAttachments = (payload['attachments'] as List?)
                  ?.whereType<Map>()
                  .map(Map<String, dynamic>.from)
                  .toList() ??
              <Map<String, dynamic>>[];
          final uploaded = await _uploadLocalAttachments(
            item['thread_id']?.toString() ?? '',
            clientMessageId,
            originalAttachments,
          );
          payload['attachments'] = uploaded;
          final result = await _sendMessageToServer(
            employeeId: employeeId,
            threadId: item['thread_id']?.toString() ?? '',
            clientMessageId: clientMessageId,
            payload: payload,
            attachments: uploaded,
          );
          final resultMap = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
          final rawMessage = resultMap['message'];
          final serverMessage = rawMessage is Map ? Map<String, dynamic>.from(rawMessage) : <String, dynamic>{};
          if (serverMessage.isNotEmpty) {
            final threadId = item['thread_id']?.toString() ?? '';
            final cached = await store.readMessages(employeeId, threadId, limit: 500);
            cached.removeWhere((row) => row['client_message_id']?.toString() == clientMessageId || row['id']?.toString() == clientMessageId);
            await store.writeMessages(employeeId, threadId, [...cached, {...serverMessage, 'local_state': 'sent'}]);
          }
          for (final attachment in originalAttachments) {
            final localPath = attachment['local_path']?.toString();
            if (localPath == null) continue;
            try {
              final file = File(localPath);
              if (await file.exists()) await file.delete();
            } catch (_) {
              // A stale local draft does not affect the delivered server message.
            }
          }
          await store.removeOutbox(clientMessageId);
          _events.add(ChatSyncEvent(
            ChatSyncEventType.messageSent,
            threadId: item['thread_id']?.toString(),
            clientMessageId: clientMessageId,
            payload: serverMessage,
          ));
        } catch (error) {
          await store.markOutboxFailed(clientMessageId, error, attempts + 1);
          await store.updateLocalMessageState(
            employeeId,
            item['thread_id']?.toString() ?? '',
            clientMessageId,
            'failed',
            error: error.toString(),
          );
          _events.add(ChatSyncEvent(
            ChatSyncEventType.messageFailed,
            threadId: item['thread_id']?.toString(),
            clientMessageId: clientMessageId,
            error: error,
          ));
          if (_looksOffline(error)) {
            _online = false;
            _events.add(ChatSyncEvent(ChatSyncEventType.disconnected, error: error));
            break;
          }
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<Map<String, dynamic>> _sendMessageToServer({
    required String employeeId,
    required String threadId,
    required String clientMessageId,
    required Map<String, dynamic> payload,
    required List<Map<String, dynamic>> attachments,
  }) async {
    // Core messages must not depend on the larger v2 RPC. That function also
    // creates notifications, receipts and inbox events, so a failure in any of
    // those secondary paths used to roll the message itself back.
    if (payload['poll'] == null) {
      final message = await _sendLegacyMessage(
        employeeId: employeeId,
        threadId: threadId,
        clientMessageId: clientMessageId,
        payload: payload,
        attachments: attachments,
      );
      return {
        'message': {...message, '_legacy_fallback': true},
        'legacy_fallback': true,
      };
    }
    try {
      final result = await client.rpc('ansar_send_chat_message_v2', params: {
        'p_employee_id': employeeId,
        'p_thread_id': threadId,
        'p_client_message_id': clientMessageId,
        'p_body': payload['body'] ?? '',
        'p_message_type': payload['message_type'] ?? 'text',
        'p_attachments': attachments,
        'p_reply_to_id': payload['reply_to_id'],
        'p_mentions': payload['mentions'] ?? <String>[],
        'p_requires_ack': payload['requires_ack'] == true,
        'p_forwarded_from_id': payload['forwarded_from_id'],
        'p_poll': payload['poll'],
      });
      return result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
    } catch (error) {
      if (!shouldFallbackToLegacyChatSend(error)) rethrow;
      final message = await _sendLegacyMessage(
        employeeId: employeeId,
        threadId: threadId,
        clientMessageId: clientMessageId,
        payload: payload,
        attachments: attachments,
      );
      return {
        'message': {...message, '_legacy_fallback': true},
        'legacy_fallback': true,
      };
    }
  }

  Future<Map<String, dynamic>> _sendLegacyMessage({
    required String employeeId,
    required String threadId,
    required String clientMessageId,
    required Map<String, dynamic> payload,
    required List<Map<String, dynamic>> attachments,
  }) async {
    if (payload['poll'] != null) {
      throw StateError('The chat upgrade is required before sending polls.');
    }
    final basicRow = <String, dynamic>{
      'thread_id': threadId,
      'sender_id': employeeId,
      'body': payload['body'] ?? '',
      'message_type': payload['message_type'] ?? 'text',
      if (attachments.isNotEmpty) 'attachments': attachments,
      if (payload['reply_to_id'] != null) 'reply_to_id': payload['reply_to_id'],
    };
    final upgradedRow = <String, dynamic>{
      ...basicRow,
      'client_message_id': clientMessageId,
      if (payload['forwarded_from_id'] != null) 'forwarded_from_id': payload['forwarded_from_id'],
      if ((payload['mentions'] as List?)?.isNotEmpty == true) 'mentions': payload['mentions'],
      if (payload['requires_ack'] == true) 'requires_ack': true,
    };
    try {
      final inserted = await client.from('ansar_chat_messages').insert(upgradedRow).select().single();
      await _touchThread(threadId);
      return Map<String, dynamic>.from(inserted);
    } catch (error) {
      if (_looksLikeDuplicate(error)) {
        try {
          final rows = await client
              .from('ansar_chat_messages')
              .select()
              .eq('sender_id', employeeId)
              .eq('client_message_id', clientMessageId)
              .limit(1);
          if (rows.isNotEmpty) return Map<String, dynamic>.from(rows.first);
        } catch (_) {
          // Continue to the legacy schema fallback below.
        }
      }
      if (!shouldRetryBasicLegacyChatInsert(error)) rethrow;
    }

    final inserted = await client.from('ansar_chat_messages').insert(basicRow).select().single();
    await _touchThread(threadId);
    return Map<String, dynamic>.from(inserted);
  }

  Future<void> _touchThread(String threadId) async {
    try {
      await client.from('ansar_chat_threads').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', threadId);
    } catch (_) {
      // Message delivery is successful even if the legacy thread timestamp fails.
    }
  }

  bool _looksLikeDuplicate(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('23505') || text.contains('duplicate key') || text.contains('unique constraint');
  }

  Future<void> _retryPendingWork() async {
    if (!_online) {
      final connectivity = await Connectivity().checkConnectivity();
      final connected = connectivity.any((result) => result != ConnectivityResult.none);
      if (connected) {
        _online = true;
        _events.add(const ChatSyncEvent(ChatSyncEventType.connected));
        _subscribeInbox();
        _subscribeMessageChanges();
      }
    }
    await flushOutbox();
  }

  Future<List<Map<String, dynamic>>> _uploadLocalAttachments(
    String threadId,
    String clientMessageId,
    List<Map<String, dynamic>> attachments,
  ) async {
    final result = <Map<String, dynamic>>[];
    final uploadedPaths = <String>[];
    try {
      for (var index = 0; index < attachments.length; index++) {
        final attachment = attachments[index];
        final localPath = attachment['local_path']?.toString();
        if (localPath == null || localPath.isEmpty) {
          result.add(attachment);
          continue;
        }
        final file = File(localPath);
        if (!await file.exists()) throw Exception('ملف المرفق غير موجود على الجهاز');
        final name = attachment['name']?.toString() ?? file.uri.pathSegments.last;
        final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final remotePath = '$threadId/$clientMessageId-$index-$safeName';
        final bytes = await file.readAsBytes();
        if (bytes.length > 10 * 1024 * 1024) throw Exception('حجم المرفق أكبر من 10 ميغابايت');
        await client.storage.from('ansar-chat').uploadBinary(
              remotePath,
              bytes,
              fileOptions: FileOptions(
                contentType: attachment['mime_type']?.toString(),
                upsert: true,
              ),
            );
        uploadedPaths.add(remotePath);
        result.add({
          'path': remotePath,
          'name': name,
          'size': bytes.length,
          'mime_type': attachment['mime_type'],
          if (attachment['duration_ms'] != null) 'duration_ms': attachment['duration_ms'],
          if (attachment['waveform'] != null) 'waveform': attachment['waveform'],
        });
      }
    } catch (_) {
      for (final path in uploadedPaths) {
        try {
          await client.storage.from('ansar-chat').remove([path]);
        } catch (_) {
          // A later storage cleanup can remove an orphaned upload.
        }
      }
      rethrow;
    }
    return result;
  }

  bool _looksOffline(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('socket') || text.contains('network') || text.contains('connection') || text.contains('timeout');
  }

  Future<void> stop() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    final channel = _inboxChannel;
    _inboxChannel = null;
    if (channel != null) await client.removeChannel(channel);
    final messageChangesChannel = _messageChangesChannel;
    _messageChangesChannel = null;
    if (messageChangesChannel != null) await client.removeChannel(messageChangesChannel);
    _inboxConnected = false;
    _messageChangesConnected = false;
    _employeeId = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

bool shouldFallbackToLegacyChatSend(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('pgrst202') ||
      text.contains('could not find the function') ||
      text.contains('ansar_send_chat_message_v2') && text.contains('not found')) {
    return true;
  }
  const upgradeObjects = <String>[
    'ansar_chat_inbox_events',
    'ansar_chat_message_receipts',
    'client_message_id',
  ];
  return (text.contains('does not exist') || text.contains('schema cache')) &&
      upgradeObjects.any(text.contains);
}

bool shouldRetryBasicLegacyChatInsert(Object error) {
  final text = error.toString().toLowerCase();
  const upgradeColumns = <String>[
    'client_message_id',
    'forwarded_from_id',
    'mentions',
    'requires_ack',
  ];
  final missingUpgradeColumn = upgradeColumns.any(text.contains);
  return missingUpgradeColumn &&
      (text.contains('does not exist') ||
          text.contains('schema cache') ||
          text.contains('pgrst204') ||
          text.contains('could not find'));
}

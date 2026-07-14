import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ansar_config.dart';

const _replyActionId = 'ansar_reply';
const _pendingRepliesKey = 'ansar_pending_notification_replies';
const _shownNotificationIdsKey = 'ansar_shown_notification_ids';

final richNotificationClicks = StreamController<Map<String, dynamic>>.broadcast();

@pragma('vm:entry-point')
Future<void> richNotificationBackgroundResponse(NotificationResponse response) async {
  DartPluginRegistrant.ensureInitialized();
  await RichNotificationService.handleResponse(response, background: true);
}

class RichNotificationService {
  RichNotificationService._();

  static final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static Map<String, dynamic>? _pendingLaunchClick;

  static Future<void> initialize() async {
    if (_initialized || !Platform.isAndroid) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('ansar_notification'),
    );
    await plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) => handleResponse(response),
      onDidReceiveBackgroundNotificationResponse: richNotificationBackgroundResponse,
    );
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'ansar_messages_v1',
        'رسائل فريق الأنصار',
        description: 'إشعارات الرسائل والمحادثات',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'ansar_updates_v1',
        'تحديثات فريق الأنصار',
        description: 'إشعارات الدوام والمناقلات والتحديثات العامة',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );
    _initialized = true;

    final launch = await plugin.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true && response?.payload != null) {
      final data = _decodePayload(response!.payload);
      if (data != null) _pendingLaunchClick = data;
    }
    unawaited(retryPendingReplies());
  }

  static Future<void> show(Map<String, dynamic> rawData) async {
    if (!Platform.isAndroid) return;
    await initialize();
    final data = rawData.map((key, value) => MapEntry(key, value?.toString() ?? ''));
    final notificationId = data['notification_id']?.toString() ?? '';
    if (notificationId.isNotEmpty && !await _claimNotification(notificationId)) return;

    final type = data['type']?.toString() ?? '';
    final isChat = type.startsWith('chat');
    final title = data['title']?.toString().trim().isNotEmpty == true
        ? data['title']!.toString()
        : (isChat ? 'رسالة جديدة' : 'فريق الأنصار');
    final body = data['body']?.toString().trim().isNotEmpty == true
        ? data['body']!.toString()
        : data['message']?.toString() ?? '';
    final senderName = data['sender_name']?.toString().trim().isNotEmpty == true
        ? data['sender_name']!.toString()
        : title;
    final senderId = data['sender_id']?.toString() ?? 'ansar';
    final threadId = data['thread_id']?.toString() ?? '';
    final avatarBytes = await _downloadAvatar(data['sender_avatar_url']?.toString());
    final sender = Person(
      name: senderName,
      key: senderId,
      icon: avatarBytes == null ? null : ByteArrayAndroidIcon(avatarBytes),
    );
    const me = Person(name: 'أنت', key: 'me');
    final payload = jsonEncode(data);
    final id = _notificationIntId(notificationId.isEmpty ? '$type-$threadId-$body' : notificationId);

    if (isChat) {
      final style = MessagingStyleInformation(
        me,
        conversationTitle: data['thread_title']?.toString().trim().isNotEmpty == true
            ? data['thread_title']!.toString()
            : senderName,
        groupConversation: data['thread_type'] != 'direct',
        messages: [Message(body, DateTime.now(), sender)],
      );
      final details = AndroidNotificationDetails(
        'ansar_messages_v1',
        'رسائل فريق الأنصار',
        channelDescription: 'إشعارات الرسائل والمحادثات',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        styleInformation: style,
        groupKey: threadId.isEmpty ? 'ansar-chat' : 'ansar-chat-$threadId',
        largeIcon: avatarBytes == null ? null : ByteArrayAndroidBitmap(avatarBytes),
        number: int.tryParse(data['unread_count']?.toString() ?? ''),
        actions: const [
          AndroidNotificationAction(
            _replyActionId,
            'رد',
            inputs: [AndroidNotificationActionInput(label: 'اكتب الرد')],
            semanticAction: SemanticAction.reply,
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      );
      await plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(android: details),
        payload: payload,
      );
      return;
    }

    final details = AndroidNotificationDetails(
      'ansar_updates_v1',
      'تحديثات فريق الأنصار',
      channelDescription: 'إشعارات الدوام والمناقلات والتحديثات العامة',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(body, contentTitle: title),
      largeIcon: avatarBytes == null ? null : ByteArrayAndroidBitmap(avatarBytes),
    );
    await plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(android: details),
      payload: payload,
    );
  }

  static Future<void> handleResponse(NotificationResponse response, {bool background = false}) async {
    final data = _decodePayload(response.payload);
    if (data == null) return;
    if (response.actionId == _replyActionId) {
      final input = response.input?.trim() ?? '';
      if (input.isEmpty) return;
      final reply = <String, dynamic>{
        'installation_id': await _installationId(),
        'thread_id': data['thread_id']?.toString() ?? '',
        'body': input,
        'notification_id': data['notification_id']?.toString() ?? '',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
      try {
        await _sendReply(reply);
      } catch (_) {
        await _queueReply(reply);
      }
      return;
    }
    if (background) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('ansar_pending_notification_click', jsonEncode(data));
    } else {
      richNotificationClicks.add(data);
    }
  }

  static Future<void> retryPendingReplies() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_pendingRepliesKey);
    if (raw == null || raw.isEmpty) return;
    List<dynamic> pending;
    try {
      pending = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      await preferences.remove(_pendingRepliesKey);
      return;
    }
    final remaining = <Map<String, dynamic>>[];
    for (final item in pending) {
      if (item is! Map) continue;
      final reply = Map<String, dynamic>.from(item);
      try {
        await _sendReply(reply);
      } catch (_) {
        remaining.add(reply);
      }
    }
    if (remaining.isEmpty) {
      await preferences.remove(_pendingRepliesKey);
    } else {
      await preferences.setString(_pendingRepliesKey, jsonEncode(remaining.take(20).toList()));
    }
  }

  static Future<void> emitPendingClick() async {
    final launchData = _pendingLaunchClick;
    if (launchData != null) {
      _pendingLaunchClick = null;
      richNotificationClicks.add(launchData);
    }
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('ansar_pending_notification_click');
    if (raw == null) return;
    await preferences.remove('ansar_pending_notification_click');
    final data = _decodePayload(raw);
    if (data != null) richNotificationClicks.add(data);
  }

  static Future<void> _sendReply(Map<String, dynamic> reply) async {
    final client = SupabaseClient(AnsarConfig.supabaseUrl, AnsarConfig.supabaseServiceKey);
    await client.rpc('ansar_send_chat_reply', params: {
      'p_installation_id': reply['installation_id'],
      'p_thread_id': reply['thread_id'],
      'p_body': reply['body'],
      'p_notification_id': reply['notification_id'],
    });
  }

  static Future<void> _queueReply(Map<String, dynamic> reply) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_pendingRepliesKey);
    final pending = <dynamic>[];
    if (raw != null) {
      try {
        pending.addAll(jsonDecode(raw) as List<dynamic>);
      } catch (_) {
        // Replace invalid local data with the new pending reply.
      }
    }
    pending.removeWhere((item) => item is Map && item['notification_id'] == reply['notification_id']);
    pending.add(reply);
    await preferences.setString(_pendingRepliesKey, jsonEncode(pending.take(20).toList()));
  }

  static Future<String> _installationId() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString('ansar_installation_id') ?? '';
  }

  static Future<bool> _claimNotification(String id) async {
    final preferences = await SharedPreferences.getInstance();
    final shown = preferences.getStringList(_shownNotificationIdsKey) ?? <String>[];
    if (shown.contains(id)) return false;
    shown.add(id);
    if (shown.length > 120) shown.removeRange(0, shown.length - 120);
    await preferences.setStringList(_shownNotificationIdsKey, shown);
    return true;
  }

  static Future<Uint8List?> _downloadAvatar(String? url) async {
    if (url == null || !url.startsWith('http')) return null;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) return null;
      }
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  static int _notificationIntId(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = 0x1fffffff & (hash + codeUnit);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= hash >> 6;
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= hash >> 11;
    return 0x7fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}

Map<String, dynamic>? _decodePayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final decoded = jsonDecode(payload);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}

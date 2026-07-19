import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Tracks whether employees are using the app, independently from the chat
/// thread they currently have open.
class ChatAppPresence {
  ChatAppPresence(this.client);

  final SupabaseClient client;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  RealtimeChannel? _channel;
  String? _employeeId;
  String? _employeeName;
  bool _tracked = false;

  Future<void> start({required String employeeId, required String employeeName}) async {
    if (_employeeId == employeeId && _channel != null) {
      _employeeName = employeeName;
      await resume();
      return;
    }
    await stop();
    _employeeId = employeeId;
    _employeeName = employeeName;
    final channel = client.channel('ansar-app-presence');
    _channel = channel
      ..onPresenceSync((_) => _notify())
      ..onPresenceJoin((_) => _notify())
      ..onPresenceLeave((_) => _notify())
      ..subscribe((status, error) async {
        if (_channel != channel || _employeeId != employeeId) return;
        if (status == RealtimeSubscribeStatus.subscribed) {
          await _track();
        } else if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          _tracked = false;
          _notify();
        }
      });
  }

  Future<void> resume() async {
    if (_channel == null || _employeeId == null) return;
    await _track();
  }

  Future<void> pause() async {
    final channel = _channel;
    if (channel == null || !_tracked) return;
    try {
      await channel.untrack();
    } catch (_) {
      // Realtime may already have disconnected while the app was backgrounded.
    }
    _tracked = false;
    _notify();
  }

  bool isAnyOnline(Iterable<String> employeeIds) {
    final channel = _channel;
    if (channel == null) return false;
    final state = channel.presenceState().toString();
    return employeeIds.any(state.contains);
  }

  Future<void> _track() async {
    final channel = _channel;
    final employeeId = _employeeId;
    if (channel == null || employeeId == null) return;
    try {
      await channel.track({
        'employee_id': employeeId,
        'employee_name': _employeeName ?? '',
        'online_at': DateTime.now().toUtc().toIso8601String(),
      });
      _tracked = true;
      _notify();
    } catch (_) {
      _tracked = false;
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> stop() async {
    await pause();
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        await client.removeChannel(channel);
      } catch (_) {
        // Removing a stale channel is best effort.
      }
    }
    _employeeId = null;
    _employeeName = null;
    _notify();
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }
}

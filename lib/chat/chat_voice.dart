import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:sqflite/sqflite.dart';

class ChatVoiceDraft {
  const ChatVoiceDraft({
    required this.path,
    required this.duration,
    required this.waveform,
  });

  final String path;
  final Duration duration;
  final List<double> waveform;

  Map<String, dynamic> toAttachment() => {
        'local_path': path,
        'name': 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
        'mime_type': 'audio/mp4',
        'duration_ms': duration.inMilliseconds,
        'waveform': waveform,
      };
}

class ChatVoiceRecorder extends ChangeNotifier {
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _stopwatch = Stopwatch();
  final List<double> _waveform = <double>[];
  Timer? _amplitudeTimer;
  Timer? _durationTimer;
  String? _path;
  bool _recording = false;
  bool _paused = false;

  bool get recording => _recording;
  bool get paused => _paused;
  Duration get duration => _stopwatch.elapsed;
  List<double> get waveform => List.unmodifiable(_waveform);

  Future<void> start() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) throw Exception('يجب السماح باستخدام الميكروفون لإرسال رسالة صوتية');
    final root = await getDatabasesPath();
    final folder = Directory('$root${Platform.pathSeparator}ansar_voice_drafts');
    if (!await folder.exists()) await folder.create(recursive: true);
    _path = '${folder.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 96000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: _path!,
    );
    _waveform.clear();
    _stopwatch
      ..reset()
      ..start();
    _recording = true;
    _paused = false;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_stopwatch.elapsed >= const Duration(minutes: 5)) {
        unawaited(stop());
      }
      notifyListeners();
    });
    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 140), (_) => unawaited(_captureAmplitude()));
    notifyListeners();
  }

  Future<void> _captureAmplitude() async {
    if (!_recording || _paused) return;
    try {
      final amplitude = await _recorder.getAmplitude();
      final normalized = ((amplitude.current + 55) / 55).clamp(0.08, 1.0).toDouble();
      _waveform.add(normalized);
      if (_waveform.length > 180) _waveform.removeAt(0);
      notifyListeners();
    } catch (_) {
      // Recording continues even if one amplitude sample cannot be read.
    }
  }

  Future<void> pauseOrResume() async {
    if (!_recording) return;
    if (_paused) {
      await _recorder.resume();
      _stopwatch.start();
      _paused = false;
    } else {
      await _recorder.pause();
      _stopwatch.stop();
      _paused = true;
    }
    notifyListeners();
  }

  Future<ChatVoiceDraft?> stop() async {
    if (!_recording) return null;
    _amplitudeTimer?.cancel();
    _durationTimer?.cancel();
    _stopwatch.stop();
    final recordedPath = await _recorder.stop() ?? _path;
    final recordedDuration = _stopwatch.elapsed;
    _recording = false;
    _paused = false;
    notifyListeners();
    if (recordedPath == null || recordedDuration < const Duration(milliseconds: 500)) {
      if (recordedPath != null) {
        try {
          await File(recordedPath).delete();
        } catch (_) {
          // The next recording cleanup can remove a short stale file.
        }
      }
      return null;
    }
    return ChatVoiceDraft(
      path: recordedPath,
      duration: recordedDuration,
      waveform: _compressWaveform(_waveform, 44),
    );
  }

  Future<void> cancel() async {
    final draft = await stop();
    final path = draft?.path ?? _path;
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // A stale draft can be cleaned during a later recording session.
      }
    }
  }

  List<double> _compressWaveform(List<double> values, int target) {
    if (values.isEmpty) return List<double>.filled(target, 0.18);
    if (values.length <= target) return [...values, ...List<double>.filled(target - values.length, 0.12)];
    final result = <double>[];
    final stride = values.length / target;
    for (var index = 0; index < target; index++) {
      final start = (index * stride).floor();
      final end = min(values.length, max(start + 1, ((index + 1) * stride).ceil()));
      result.add(values.sublist(start, end).reduce(max));
    }
    return result;
  }

  @override
  void dispose() {
    _amplitudeTimer?.cancel();
    _durationTimer?.cancel();
    unawaited(_recorder.dispose());
    super.dispose();
  }
}

class ChatVoicePlayer extends StatefulWidget {
  const ChatVoicePlayer({
    super.key,
    required this.sourceResolver,
    required this.duration,
    this.waveform = const [],
    this.color = const Color(0xff147a68),
  });

  final Future<String?> Function() sourceResolver;
  final Duration duration;
  final List<double> waveform;
  final Color color;

  @override
  State<ChatVoicePlayer> createState() => _ChatVoicePlayerState();
}

class _ChatVoicePlayerState extends State<ChatVoicePlayer> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Duration _position = Duration.zero;
  bool _loading = false;
  bool _loaded = false;
  double _speed = 1;

  @override
  void initState() {
    super.initState();
    _stateSubscription = _player.playerStateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _positionSubscription = _player.positionStream.listen((position) {
      if (mounted) setState(() => _position = position);
    });
  }

  Future<void> _toggle() async {
    if (_loading) return;
    if (!_loaded) {
      setState(() => _loading = true);
      try {
        final source = await widget.sourceResolver();
        if (source == null || source.isEmpty) throw Exception('تعذر فتح الرسالة الصوتية');
        if (source.startsWith('http')) {
          await _player.setUrl(source);
        } else {
          await _player.setFilePath(source);
        }
        _loaded = true;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) await _player.seek(Duration.zero);
      await _player.play();
    }
  }

  Future<void> _cycleSpeed() async {
    _speed = _speed == 1 ? 1.5 : (_speed == 1.5 ? 2 : 1);
    await _player.setSpeed(_speed);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = max(1, (_player.duration ?? widget.duration).inMilliseconds);
    final progress = (_position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final bars = widget.waveform.isEmpty ? List<double>.generate(34, (index) => 0.18 + (index % 6) * 0.08) : widget.waveform;
    return SizedBox(
      width: 232,
      child: Row(
        children: [
          IconButton.filledTonal(
            tooltip: _player.playing ? 'إيقاف مؤقت' : 'تشغيل',
            onPressed: _toggle,
            icon: _loading
                ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 30,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final visible = min(bars.length, max(1, constraints.maxWidth ~/ 4));
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (var index = 0; index < visible; index++)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 1),
                                child: Container(
                                  height: 5 + bars[index] * 22,
                                  decoration: BoxDecoration(
                                    color: index / visible <= progress ? widget.color : widget.color.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                Text(_format(_position == Duration.zero ? widget.duration : _position), style: const TextStyle(fontSize: 9)),
              ],
            ),
          ),
          TextButton(onPressed: _cycleSpeed, child: Text('${_speed}x', style: const TextStyle(fontSize: 10))),
        ],
      ),
    );
  }

  String _format(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }
}

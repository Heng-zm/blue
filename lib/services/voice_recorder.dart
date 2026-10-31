import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class RecordedVoice {
  const RecordedVoice({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.durationMs,
  });

  final String path;
  final String name;
  final String mimeType;
  final int durationMs;
}

/// Thin cross-platform wrapper around `record`.
///
/// Android and iOS produce compact AAC-LC (`.m4a`). Windows records PCM WAV,
/// which Media Foundation plays everywhere and avoids missing AAC encoders.
class VoiceRecorder {
  VoiceRecorder();

  final AudioRecorder _recorder = AudioRecorder();
  Stopwatch? _stopwatch;
  String? _path;
  bool _recording = false;

  bool get isRecording => _recording;

  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  Future<bool> start() async {
    if (_recording) return true;
    if (!await hasPermission()) return false;

    final windows = Platform.isWindows;
    final directory = await getTemporaryDirectory();
    final extension = windows ? 'wav' : 'm4a';
    final name =
        'mgs-voice-${DateTime.now().millisecondsSinceEpoch}.$extension';
    final path = p.join(directory.path, name);

    final config = windows
        ? const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          )
        : const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 32000,
            sampleRate: 22050,
            numChannels: 1,
            autoGain: true,
            echoCancel: true,
            noiseSuppress: true,
          );

    try {
      await _recorder.start(config, path: path);
    } catch (_) {
      return false;
    }
    _path = path;
    _recording = true;
    _stopwatch = Stopwatch()..start();
    return true;
  }

  Future<RecordedVoice?> stop() async {
    if (!_recording) return null;
    _recording = false;
    final elapsed = _stopwatch?.elapsed ?? Duration.zero;
    _stopwatch?.stop();
    _stopwatch = null;

    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }
    path ??= _path;
    _path = null;
    if (path == null) return null;

    final file = File(path);
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length == 0) {
      await _deleteQuietly(file);
      return null;
    }

    final durationMs = elapsed.inMilliseconds.clamp(1, 60 * 1000);
    return RecordedVoice(
      path: path,
      name: p.basename(path),
      mimeType: Platform.isWindows ? 'audio/wav' : 'audio/mp4',
      durationMs: durationMs,
    );
  }

  Future<void> cancel() async {
    if (!_recording) {
      final path = _path;
      _path = null;
      if (path != null) await _deleteQuietly(File(path));
      return;
    }
    _recording = false;
    _stopwatch?.stop();
    _stopwatch = null;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }
    path ??= _path;
    _path = null;
    if (path != null) await _deleteQuietly(File(path));
  }

  Future<void> dispose() async {
    await cancel();
    try {
      await _recorder.dispose();
    } catch (_) {
      // Already disposed.
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Temporary storage is cleaned up by the OS.
    }
  }
}

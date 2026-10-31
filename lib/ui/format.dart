String clockTime(DateTime time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String chatTimestamp(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final difference = today.difference(day).inDays;

  if (difference == 0) return clockTime(time);
  if (difference == 1) return 'Yesterday';
  if (difference < 7) {
    const weekdays = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[time.weekday - 1];
  }
  return '${time.day}/${time.month}';
}

String logTimestamp(DateTime time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  final second = time.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}

/// Human-readable byte count. Keeps file bubbles compact.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final value = bytes / 1024;
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} KB';
  }
  final value = bytes / (1024 * 1024);
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} MB';
}

/// Human-readable transfer rate (e.g. `48 KB/s` or `1.5 MB/s`).
String formatSpeed(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '';
  if (bytesPerSecond < 1024) {
    return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  }
  if (bytesPerSecond < 1024 * 1024) {
    final kb = bytesPerSecond / 1024;
    return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB/s';
  }
  final mb = bytesPerSecond / (1024 * 1024);
  return '${mb.toStringAsFixed(1)} MB/s';
}

/// Human-readable ETA countdown (e.g. `ETA 15s` or `ETA 1m 20s`).
String formatEta(int? seconds) {
  if (seconds == null || seconds <= 0) return '';
  if (seconds < 60) return 'ETA ${seconds}s';
  final minutes = seconds ~/ 60;
  final remaining = seconds % 60;
  return 'ETA ${minutes}m ${remaining.toString().padLeft(2, '0')}s';
}

/// `m:ss` for voice note durations.
String durationLabel(int milliseconds) {
  final totalSeconds = (milliseconds / 1000).round().clamp(0, 9999);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String signalLabel(int rssi) {
  if (rssi >= -55) return 'strong';
  if (rssi >= -70) return 'good';
  if (rssi >= -85) return 'weak';
  return 'faint';
}

String relativeAge(DateTime time) {
  final seconds = DateTime.now().difference(time).inSeconds;
  if (seconds < 5) return 'just now';
  if (seconds < 60) return '${seconds}s ago';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ago';
  return chatTimestamp(time);
}

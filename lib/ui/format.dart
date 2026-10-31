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

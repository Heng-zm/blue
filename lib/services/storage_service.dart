import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/ids.dart';
import '../models/message.dart';

class StoredData {
  StoredData({
    required this.peerId,
    required this.displayName,
    required this.messages,
    this.ttl = defaultTtl,
    this.relayEnabled = true,
    this.radioEnabled = true,
  });

  final String peerId;
  String displayName;
  final List<Message> messages;
  int ttl;
  bool relayEnabled;
  bool radioEnabled;
}

/// JSON-file persistence. Deliberately dependency-light and cross-platform;
/// messages are capped so the file stays small.
class StorageService {
  StorageService({this.fileName = 'mgs_state.json'});

  final String fileName;
  File? _cachedFile;

  Future<File> _file() async {
    final cached = _cachedFile;
    if (cached != null) return cached;
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    _cachedFile = file;
    return file;
  }

  Future<StoredData> load() async {
    final file = await _file();
    if (!await file.exists()) {
      return StoredData(
        peerId: newPeerId(),
        displayName: '',
        messages: <Message>[],
      );
    }

    Map<String, dynamic> json;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Root is not an object.');
      }
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      await _backupCorrupt(file);
      return StoredData(
        peerId: newPeerId(),
        displayName: '',
        messages: <Message>[],
      );
    }

    final rawPeerId = json['peerId'];
    final peerId = rawPeerId is String && isPeerId(rawPeerId)
        ? rawPeerId
        : newPeerId();

    final rawName = json['displayName'];
    final trimmedName = rawName is String ? rawName.trim() : '';
    final displayName = trimmedName.length > maxDisplayNameLength
        ? trimmedName.substring(0, maxDisplayNameLength)
        : trimmedName;

    final messages = <Message>[];
    final rawMessages = json['messages'];
    if (rawMessages is List) {
      for (final entry in rawMessages) {
        if (entry is! Map) continue;
        try {
          messages.add(Message.fromStorage(Map<String, dynamic>.from(entry)));
        } catch (_) {
          // Skip a single damaged message instead of losing the whole archive.
        }
      }
    }
    messages.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    while (messages.length > maxStoredMessages) {
      messages.removeAt(0);
    }

    final rawTtl = json['ttl'];
    final ttl = rawTtl is int
        ? (rawTtl < minTtl ? minTtl : (rawTtl > maxTtl ? maxTtl : rawTtl))
        : defaultTtl;

    return StoredData(
      peerId: peerId,
      displayName: displayName,
      messages: messages,
      ttl: ttl,
      relayEnabled: json['relayEnabled'] is bool
          ? json['relayEnabled'] as bool
          : true,
      radioEnabled: json['radioEnabled'] is bool
          ? json['radioEnabled'] as bool
          : true,
    );
  }

  Future<void> save(StoredData data) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final encoded = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{
          'version': 1,
          'peerId': data.peerId,
          'displayName': data.displayName,
          'ttl': data.ttl,
          'relayEnabled': data.relayEnabled,
          'radioEnabled': data.radioEnabled,
          'messages': data.messages
              .map((message) => message.toStorage())
              .toList(),
        });

    final temp = File('${file.path}.tmp');
    await temp.writeAsString(encoded, flush: true);
    try {
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } catch (_) {
      // Some filesystems (or a virus scanner holding the file) refuse the
      // rename. Fall back to a direct write so a save is never silently lost.
      await file.writeAsString(encoded, flush: true);
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {
          // Best effort.
        }
      }
    }
  }

  Future<void> _backupCorrupt(File file) async {
    try {
      final backup =
          '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      await file.rename(backup);
    } catch (_) {
      // If the file cannot be moved we simply start fresh next time.
    }
  }
}

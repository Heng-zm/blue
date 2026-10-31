import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/ids.dart';
import '../models/message.dart';
import '../models/peer.dart';
import '../protocol/binary.dart';
import '../protocol/blob_codec.dart';
import '../protocol/frame.dart';
import '../protocol/mesh_router.dart';
import '../protocol/message_codec.dart';
import '../security/mesh_cipher.dart';
import '../services/ble_transport.dart';
import '../services/blob_store.dart';
import '../services/lan_transport.dart';
import '../services/storage_service.dart';

class LogLine {
  LogLine(this.message, this.level, {DateTime? time})
    : time = time ?? DateTime.now();

  final String message;
  final BleLogLevel level;
  final DateTime time;
}

class ChatSummary {
  const ChatSummary({
    required this.threadId,
    required this.title,
    required this.subtitle,
    required this.unread,
    required this.isBroadcast,
    required this.online,
    required this.updatedAt,
    this.lastMessage,
  });

  final String threadId;
  final String title;
  final String subtitle;
  final int unread;
  final bool isBroadcast;
  final bool online;
  final DateTime updatedAt;
  final Message? lastMessage;
}

/// UI-facing state and the glue between the radio, router, and disk.
class AppController extends ChangeNotifier {
  AppController({StorageService? storage, BlobStore? blobs})
    : _storage = storage ?? StorageService(),
      _blobs = blobs ?? BlobStore();

  final StorageService _storage;
  final BlobStore _blobs;

  String peerId = '';
  String displayName = '';
  String passphrase = '';
  int ttl = defaultTtl;
  bool relayEnabled = true;
  bool radioEnabled = true;
  bool firstRun = true;
  bool initialized = false;
  String? warning;

  MeshRouter? _router;
  MeshCipher? _meshCipher;
  BleTransport? _transport;
  StreamSubscription<BleEvent>? _transportSubscription;
  LanTransport? _lanTransport;
  StreamSubscription<LanEvent>? _lanSubscription;
  List<String> _localIps = [];
  bool _usbConnected = false;

  final List<Message> _messages = [];
  final Map<String, Peer> _peers = {};
  final Map<String, NearbyDevice> _nearby = {};
  final List<LogLine> _logs = [];
  final Map<String, int> _unread = {};
  final Map<String, Message> _outbox = {};
  final Map<String, int> _attempts = {};
  final Map<String, int> _blobAttempts = {};
  final Map<String, _IncomingBlob> _incomingBlobs = {};
  final Set<String> _sendingIds = {};
  final Set<String> _startedBlobTransfers = {};

  BluetoothLowEnergyState _bleState = BluetoothLowEnergyState.unknown;
  bool _advertising = false;
  bool _scanning = false;
  bool _radioActive = false;

  String? _activeThreadId;
  Timer? _saveTimer;
  Timer? _retryTimer;
  bool _saveInFlight = false;
  bool _saveQueued = false;
  bool _retryInFlight = false;
  bool _booting = false;
  bool _disposed = false;
  DateTime _lastNearbyNotify = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastTransferNotify = 0;
  Future<void> _dataQueue = Future<void>.value();

  // ---------------------------------------------------------------------------
  // Read-only state for widgets
  // ---------------------------------------------------------------------------

  BluetoothLowEnergyState get bleState => _bleState;
  bool get advertising => _advertising;
  bool get scanning => _scanning;
  bool get radioActive => _radioActive;
  String? get activeThreadId => _activeThreadId;
  List<LogLine> get logs => List.unmodifiable(_logs);
  int get messageCount => _messages.length;
  bool get hasPeers => _peers.values.any((peer) => peer.connected);
  bool get encryptionEnabled => _meshCipher != null;
  String get encryptionLabel => _meshCipher == null ? 'Off' : 'On';
  int get incomingTransferCount => _incomingBlobs.length;
  bool get lanActive => _lanTransport?.hasReadyLinks == true;
  List<String> get localIps => List.unmodifiable(_localIps);
  bool get usbConnected => _usbConnected;
  Peer? peerFor(String id) => _peers[id];

  bool get bluetoothReady => _bleState == BluetoothLowEnergyState.poweredOn;

  bool get bluetoothBlocked =>
      _bleState == BluetoothLowEnergyState.poweredOff ||
      _bleState == BluetoothLowEnergyState.unauthorized ||
      _bleState == BluetoothLowEnergyState.unsupported;

  bool get needsPermission => _bleState == BluetoothLowEnergyState.unauthorized;

  String get bluetoothStateLabel => switch (_bleState) {
    BluetoothLowEnergyState.poweredOn => 'Bluetooth on',
    BluetoothLowEnergyState.poweredOff => 'Bluetooth off',
    BluetoothLowEnergyState.unauthorized => 'Permission needed',
    BluetoothLowEnergyState.unsupported => 'Not supported',
    BluetoothLowEnergyState.unknown => 'Starting…',
  };

  int get totalUnread =>
      _unread.values.fold(0, (total, value) => total + value);

  List<Peer> get peers {
    final list = _peers.values.toList();
    list.sort((a, b) {
      if (a.connected != b.connected) return a.connected ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  List<NearbyDevice> get nearbyDevices {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 2));
    final merged = <String, NearbyDevice>{};

    for (final device in _nearby.values) {
      if (!device.connected && device.lastSeen.isBefore(cutoff)) continue;
      final key = device.peerId ?? device.address;
      final current = merged[key];
      if (current == null || device.lastSeen.isAfter(current.lastSeen)) {
        merged[key] = NearbyDevice(
          address: current?.address ?? device.address,
          rssi: device.rssi,
          peerId: device.peerId ?? current?.peerId,
          name: device.name ?? current?.name,
          connected: device.connected || (current?.connected ?? false),
          lastSeen: device.lastSeen,
        );
      } else if (device.connected && !current.connected) {
        current.connected = true;
      }
    }

    for (final peer in _peers.values) {
      if (!peer.connected) continue;
      merged.putIfAbsent(
        peer.id,
        () => NearbyDevice(
          address: peer.id,
          rssi: -55,
          peerId: peer.id,
          name: peer.name,
          connected: true,
          lastSeen: peer.lastSeen,
        ),
      );
    }

    final list = merged.values.toList();
    list.sort((a, b) {
      if (a.connected != b.connected) return a.connected ? -1 : 1;
      final bySignal = b.rssi.compareTo(a.rssi);
      if (bySignal != 0) return bySignal;
      return b.lastSeen.compareTo(a.lastSeen);
    });
    return list;
  }

  List<ChatSummary> get chats {
    final byThread = <String, List<Message>>{};
    for (final message in _messages) {
      byThread.putIfAbsent(message.threadId, () => <Message>[]).add(message);
    }

    final summaries = <ChatSummary>[];
    for (final entry in byThread.entries) {
      final threadId = entry.key;
      final messages = entry.value
        ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      final last = messages.last;
      final isBroadcast = threadId == broadcastRecipient;
      final peer = _peers[threadId];
      final title = isBroadcast
          ? 'Nearby'
          : (peer?.name ??
                (last.outgoing
                    ? 'MGS ${shortPeerId(threadId)}'
                    : last.fromName));
      final subtitle = isBroadcast
          ? (last.outgoing
                ? 'You: ${last.preview}'
                : '${last.fromName}: ${last.preview}')
          : (last.outgoing ? 'You: ${last.preview}' : last.preview);

      summaries.add(
        ChatSummary(
          threadId: threadId,
          title: title,
          subtitle: subtitle,
          unread: _unread[threadId] ?? 0,
          isBroadcast: isBroadcast,
          online: isBroadcast
              ? _peers.values.any((p) => p.connected)
              : (peer?.connected ?? false),
          updatedAt: last.timestamp,
          lastMessage: last,
        ),
      );
    }

    if (!byThread.containsKey(broadcastRecipient)) {
      summaries.add(
        ChatSummary(
          threadId: broadcastRecipient,
          title: 'Nearby',
          subtitle: 'Open channel · everyone in range',
          unread: 0,
          isBroadcast: true,
          online: _peers.values.any((p) => p.connected),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
    }

    summaries.sort((a, b) {
      if (a.isBroadcast != b.isBroadcast) return a.isBroadcast ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return summaries;
  }

  bool isPeerOnline(String peerId) => _peers[peerId]?.connected ?? false;

  String titleForThread(String threadId) {
    if (threadId == broadcastRecipient) return 'Nearby';
    return _peers[threadId]?.name ?? 'MGS ${shortPeerId(threadId)}';
  }

  List<Message> messagesFor(String threadId) {
    final list = _messages
        .where((message) => message.threadId == threadId)
        .toList();
    list.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    return list;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> bootstrap() async {
    if (_booting || initialized) return;
    _booting = true;

    try {
      final data = await _storage.load();
      peerId = data.peerId;
      displayName = data.displayName;
      ttl = data.ttl;
      relayEnabled = data.relayEnabled;
      radioEnabled = data.radioEnabled;
      passphrase = data.passphrase;

      if (passphrase.trim().isNotEmpty) {
        try {
          _meshCipher = await MeshCipher.derive(passphrase);
        } catch (error) {
          warning =
              'The saved mesh passphrase could not be loaded. Messages will '
              'be sent unencrypted until it is set again.\n$error';
          _addLog('Passphrase failed: $error', BleLogLevel.error);
          passphrase = '';
          _meshCipher = null;
        }
      }

      _messages.addAll(data.messages);
      await _restoreAttachmentPaths();

      // Rebuild the outbox for messages that never left, or that were sent
      // directly but never acknowledged. Old entries expire on the first retry
      // tick rather than flooding the mesh after a long gap.
      for (final message in data.messages) {
        final needsRetry =
            message.outgoing &&
            (message.status == MessageStatus.queued ||
                (message.status == MessageStatus.sent &&
                    (!message.isAttachment || message.transferProgress < 1)));
        if (needsRetry) {
          _outbox[message.id] = message;
          _attempts[message.id] = 0;
        }
      }
      firstRun = displayName.trim().isEmpty;
      _router = MeshRouter(
        selfId: peerId,
        selfName: displayName.isEmpty ? 'MGS user' : displayName,
      );
      _router!.seedSeen(_messages.map((message) => message.id));
      _rebuildPeersFromMessages();
    } catch (error) {
      peerId = newPeerId();
      displayName = '';
      firstRun = true;
      warning =
          'Could not open saved data. Messages will still work, but may '
          'not be persisted.\n$error';
      _router = MeshRouter(selfId: peerId, selfName: 'MGS user');
      _addLog('Storage failed: $error', BleLogLevel.error);
    }

    initialized = true;
    _retryTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(_retryPending()),
    );
    notifyListeners();

    if (!firstRun && radioEnabled) {
      unawaited(_startTransport());
    }
    _booting = false;
  }

  Future<void> _restoreAttachmentPaths() async {
    for (final message in _messages) {
      final attachment = message.attachment;
      if (attachment == null || attachment.path != null) continue;
      final path = await _blobs.find(attachment.blobId, attachment.name);
      if (path != null) {
        attachment.path = path;
        message.transferProgress = 1;
        message.transferError = null;
      } else if (!message.outgoing) {
        message.transferError ??= 'Transfer was interrupted';
      }
    }
  }

  Future<void> completeOnboarding(String name) async {
    final trimmed = normalizeDisplayName(name);
    if (name.trim().isEmpty) return;
    displayName = trimmed;
    firstRun = false;
    _router ??= MeshRouter(selfId: peerId, selfName: displayName);
    _router!.selfName = displayName;
    _transport?.setDisplayName(displayName);
    _lanTransport?.setDisplayName(displayName);
    notifyListeners();
    await _saveNow();
    if (radioEnabled) await _startTransport();
  }

  Future<void> updateDisplayName(String name) async {
    if (name.trim().isEmpty) return;
    displayName = normalizeDisplayName(name);
    _router?.selfName = displayName;
    _transport?.setDisplayName(displayName);
    _lanTransport?.setDisplayName(displayName);
    notifyListeners();
    await _saveNow();
  }

  /// Sets or clears the shared mesh passphrase. Returns an error message, or
  /// `null` on success.
  Future<String?> updatePassphrase(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      passphrase = '';
      _meshCipher = null;
      notifyListeners();
      await _saveNow();
      return null;
    }
    if (normalized.length < minPassphraseLength) {
      return 'Use at least $minPassphraseLength characters.';
    }
    if (normalized.length > maxPassphraseLength) {
      return 'Use at most $maxPassphraseLength characters.';
    }
    if (normalized == passphrase && _meshCipher != null) return null;

    try {
      final cipher = await MeshCipher.derive(normalized);
      _meshCipher = cipher;
      passphrase = normalized;
    } catch (error) {
      _addLog('Passphrase failed: $error', BleLogLevel.error);
      return 'The passphrase could not be applied.';
    }

    notifyListeners();
    await _saveNow();
    return null;
  }

  void updateTtl(int value) {
    final next = value < minTtl ? minTtl : (value > maxTtl ? maxTtl : value);
    if (ttl == next) return;
    ttl = next;
    _scheduleSave();
    notifyListeners();
  }

  void setRelayEnabled(bool value) {
    if (relayEnabled == value) return;
    relayEnabled = value;
    _scheduleSave();
    notifyListeners();
  }

  Future<void> setRadioEnabled(bool enabled) async {
    if (radioEnabled == enabled) return;
    radioEnabled = enabled;
    if (enabled) {
      await _startTransport();
    } else {
      await _stopTransport();
    }
    _scheduleSave();
    notifyListeners();
  }

  Future<void> pauseForBackground() async {
    await _transport?.pauseScanning();
  }

  Future<void> resumeFromBackground() async {
    await _transport?.resumeScanning();
  }

  Future<void> openBluetoothSettings() async {
    await _transport?.showAppSettings();
  }

  Future<void> clearHistory() async {
    final paths = _messages
        .map((message) => message.attachment?.path)
        .whereType<String>()
        .toList();
    _messages.clear();
    _outbox.clear();
    _attempts.clear();
    _blobAttempts.clear();
    _unread.clear();
    _incomingBlobs.clear();
    _startedBlobTransfers.clear();
    for (final path in paths) {
      unawaited(_blobs.deletePath(path));
    }
    await _blobs.clear();
    _scheduleSave();
    notifyListeners();
  }

  void enterThread(String threadId) {
    _activeThreadId = threadId;
    if ((_unread[threadId] ?? 0) > 0) {
      _unread.remove(threadId);
      notifyListeners();
    }
  }

  void leaveThread(String threadId) {
    if (_activeThreadId == threadId) _activeThreadId = null;
  }

  // ---------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------

  Future<bool> sendMessage(String threadId, String text) async {
    final router = _router;
    if (router == null) return false;
    final body = text.trim();
    if (body.isEmpty) return false;

    Message message;
    try {
      message = router.createOutgoing(
        to: threadId == broadcastRecipient ? broadcastRecipient : threadId,
        text: body,
        ttl: ttl,
        encrypted: _meshCipher != null,
      );
    } catch (error) {
      _addLog('Cannot send: $error', BleLogLevel.warning);
      return false;
    }

    _messages.add(message);
    _outbox[message.id] = message;
    _attempts[message.id] = 0;

    await _sendOutboxMessage(message);

    _trimMessages();
    _scheduleSave();
    notifyListeners();
    return true;
  }

  /// Picks and sends a file. Returns an error message, or `null` on success.
  Future<String?> sendFile(
    String threadId, {
    required String name,
    required Uint8List bytes,
    String? mimeType,
  }) {
    return _sendAttachment(
      threadId,
      kind: MessageKind.file,
      name: name,
      bytes: bytes,
      mimeType: mimeType ?? _mimeForName(name),
      durationMs: 0,
    );
  }

  /// Sends a recorded voice note. The temporary recording is removed after a
  /// copy has been stored locally.
  Future<String?> sendVoice(
    String threadId, {
    required String path,
    required String name,
    required String mimeType,
    required int durationMs,
  }) async {
    if (durationMs < 500) return 'The voice note is too short.';
    if (durationMs > maxVoiceSeconds * 1000) {
      return 'Voice notes are limited to $maxVoiceSeconds seconds.';
    }
    final file = File(path);
    Uint8List bytes;
    try {
      if (!await file.exists()) return 'The recording is missing.';
      bytes = await file.readAsBytes();
    } catch (error) {
      return 'Could not read the recording: $error';
    }
    final result = await _sendAttachment(
      threadId,
      kind: MessageKind.voice,
      name: name,
      bytes: bytes,
      mimeType: mimeType,
      durationMs: durationMs,
    );
    if (result == null) {
      try {
        await file.delete();
      } catch (_) {
        // The OS cleans temporary storage eventually.
      }
    }
    return result;
  }

  Future<String?> _sendAttachment(
    String threadId, {
    required MessageKind kind,
    required String name,
    required Uint8List bytes,
    required String mimeType,
    required int durationMs,
  }) async {
    final router = _router;
    if (router == null) return 'The mesh is not ready yet.';
    if (bytes.length > maxFileBytes) {
      return 'Files are limited to ${maxFileBytes ~/ (1024 * 1024)} MB.';
    }

    final safeName = normalizeFileName(name);
    final mime = _normalizeMime(mimeType);
    if (mime.isEmpty) return 'Unsupported file type.';

    final blobId = newMessageId();
    final transferId = randomHex(4);
    final blobNonce = randomHex(12);
    final encrypted = _meshCipher != null;
    final cipherBytes = bytes.length + (encrypted ? MeshCipher.overhead : 0);
    final chunkCount = blobChunkCount(cipherBytes);
    final digest = sha256.convert(bytes).toString();

    String path;
    try {
      path = await _blobs.saveBytes(
        blobId: blobId,
        name: safeName,
        bytes: bytes,
      );
    } catch (error) {
      return 'Could not store the attachment: $error';
    }

    final attachment = MessageAttachment(
      blobId: blobId,
      transferId: transferId,
      blobNonce: blobNonce,
      name: safeName,
      mimeType: mime,
      size: bytes.length,
      cipherBytes: cipherBytes,
      chunkCount: chunkCount,
      digest: digest,
      durationMs: durationMs,
      path: path,
    );

    Message message;
    try {
      message = router.createOutgoing(
        to: threadId == broadcastRecipient ? broadcastRecipient : threadId,
        text: '',
        ttl: ttl,
        kind: kind,
        attachment: attachment,
        encrypted: encrypted,
      );
    } catch (error) {
      _addLog('Cannot send attachment: $error', BleLogLevel.warning);
      return 'Could not send the attachment.';
    }

    _messages.add(message);
    _outbox[message.id] = message;
    _attempts[message.id] = 0;
    message.transferProgress = 0;

    await _sendOutboxMessage(message);
    _trimMessages();
    _scheduleSave();
    notifyListeners();
    return null;
  }

  Future<bool> _sendOutboxMessage(Message message) async {
    final transport = _transport;
    final lan = _lanTransport;
    if (transport == null && lan == null) return false;
    if (!_sendingIds.add(message.id)) return false;

    try {
      Uint8List payload;
      try {
        payload = await _encodeMessage(message);
      } catch (error) {
        _addLog('Cannot encode message: $error', BleLogLevel.warning);
        return false;
      }

      if (message.isBroadcast) {
        final sentLan = lan?.broadcast(FrameType.message, payload) ?? 0;
        final sentBle = transport?.broadcast(FrameType.message, payload) ?? 0;
        final sent = (sentLan + sentBle) > 0;
        if (sent) {
          message.status = MessageStatus.sent;
          _outbox.remove(message.id);
          _attempts.remove(message.id);
          _afterMetadataSent(message);
        }
        return sent;
      }

      var sent = false;
      if (lan != null) {
        sent = lan.sendToPeer(message.to, FrameType.message, payload);
      }
      if (!sent && transport != null) {
        sent = transport.sendToPeer(message.to, FrameType.message, payload);
      }
      if (!sent) {
        final sentLan = lan?.broadcast(FrameType.message, payload) ?? 0;
        final sentBle = transport?.broadcast(FrameType.message, payload) ?? 0;
        sent = (sentLan + sentBle) > 0;
      }
      if (sent) {
        message.status = MessageStatus.sent;
        _afterMetadataSent(message);
      }
      return sent;
    } finally {
      _sendingIds.remove(message.id);
    }
  }

  void _afterMetadataSent(Message message) {
    if (message.isAttachment) {
      unawaited(_startBlobTransfer(message));
    }
  }

  Future<Uint8List> _encodeMessage(Message message) async {
    final header = MessageHeader(
      id: message.id,
      from: message.from,
      to: message.to,
      fromName: message.fromName,
      timestampMs: message.timestampMs,
      ttl: message.ttl,
      hops: message.hops,
      kind: message.kind,
      encrypted: message.encrypted,
    );

    Uint8List plain;
    if (message.kind == MessageKind.text) {
      plain = Uint8List.fromList(utf8.encode(message.text));
    } else {
      final attachment = message.attachment;
      if (attachment == null) {
        throw StateError('Attachment metadata is missing.');
      }
      plain = BlobMetadata(
        kind: message.kind,
        blobId: attachment.blobId,
        transferId: attachment.transferId,
        blobNonce: attachment.blobNonce,
        name: attachment.name,
        mimeType: attachment.mimeType,
        size: attachment.size,
        cipherBytes: attachment.cipherBytes,
        chunkCount: attachment.chunkCount,
        digest: attachment.digest,
        durationMs: attachment.durationMs,
      ).encode();
    }

    if (message.encrypted) {
      final cipher = _meshCipher;
      if (cipher == null) {
        throw StateError('The mesh passphrase is not set.');
      }
      final contentLength = plain.length + MeshCipher.overhead;
      final aad = messageAadFor(header, contentLength);
      final content = await cipher.encrypt(plain, aad: aad);
      return MessageEnvelope.build(header, content).raw;
    }
    return MessageEnvelope.build(header, plain).raw;
  }

  Future<void> _startBlobTransfer(Message message) async {
    final attachment = message.attachment;
    if (attachment == null || attachment.path == null) return;
    if (message.transferProgress >= 1) return;
    if (!_startedBlobTransfers.add(message.id)) return;

    message.transferProgress = 0;
    message.transferError = null;
    notifyListeners();

    try {
      Uint8List bytes;
      try {
        bytes = await File(attachment.path!).readAsBytes();
      } catch (error) {
        throw StateError('Cannot read the local attachment: $error');
      }
      if (bytes.length != attachment.size) {
        throw StateError('The local attachment changed on disk.');
      }

      Uint8List ciphertext;
      final cipher = _meshCipher;
      if (message.encrypted) {
        if (cipher == null) {
          throw StateError('The mesh passphrase is not set.');
        }
        ciphertext = await cipher.encrypt(
          bytes,
          aad: blobAad(attachment.blobId, attachment.transferId),
          nonce: bytesFromHex(attachment.blobNonce, byteLength: 12),
        );
      } else {
        ciphertext = bytes;
      }
      if (ciphertext.length != attachment.cipherBytes) {
        throw StateError('Attachment encryption size changed.');
      }

      final transferStart = DateTime.now();
      var bytesSent = 0;
      final count = attachment.chunkCount;
      for (var index = 0; index < count; index++) {
        if (_disposed) return;
        if (!await _waitForBlobCapacity()) {
          throw StateError('The radio is busy or stopped.');
        }
        final current = _transport;
        final lan = _lanTransport;
        if (current == null && lan == null) {
          throw StateError('Transport stopped.');
        }

        final start = index * blobChunkPayloadBytes;
        final end = min(start + blobChunkPayloadBytes, ciphertext.length);
        final chunk = BlobChunk(
          blobId: attachment.blobId,
          transferId: attachment.transferId,
          to: message.to,
          index: index,
          count: count,
          totalLength: ciphertext.length,
          ttl: message.ttl,
          hops: message.hops,
          data: Uint8List.sublistView(ciphertext, start, end),
        ).encode();

        var sent = false;
        if (!message.isBroadcast && lan != null) {
          sent = lan.sendToPeer(message.to, FrameType.blob, chunk);
        }
        if (!sent && current != null && !message.isBroadcast) {
          sent = current.sendToPeer(message.to, FrameType.blob, chunk);
        }
        if (!sent) {
          final sentLan = lan?.broadcast(FrameType.blob, chunk) ?? 0;
          final sentBle = current?.broadcast(FrameType.blob, chunk) ?? 0;
          sent = (sentLan + sentBle) > 0;
        }
        if (!sent) {
          if (!await _waitForReadyLink()) {
            throw StateError('No peer is connected.');
          }
          index--;
          continue;
        }

        bytesSent += (end - start);
        final elapsed =
            DateTime.now().difference(transferStart).inMilliseconds / 1000.0;
        if (elapsed > 0.15) {
          message.transferSpeed = bytesSent / elapsed;
          final remainingBytes = ciphertext.length - bytesSent;
          if (message.transferSpeed > 10) {
            message.transferEtaSeconds =
                (remainingBytes / message.transferSpeed).ceil();
          }
        }

        message.transferProgress = (index + 1) / count;
        _notifyTransferProgress();
      }

      message.transferProgress = 1;
      message.transferSpeed = 0;
      message.transferEtaSeconds = null;
      message.transferError = null;
      _startedBlobTransfers.remove(message.id);
      _blobAttempts.remove(message.id);
      _addLog(
        'Sent ${message.kind.name} ${attachment.name} '
        '(${attachment.size} bytes)',
      );
    } catch (error) {
      message.transferError = 'Transfer interrupted';
      message.transferSpeed = 0;
      message.transferEtaSeconds = null;
      _startedBlobTransfers.remove(message.id);
      _addLog('Transfer failed: $error', BleLogLevel.warning);
    }

    _scheduleSave();
    notifyListeners();
  }

  Future<bool> _waitForBlobCapacity() async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!_disposed) {
      final blePending = _transport?.pendingBytes ?? 0;
      final lanPending = _lanTransport?.pendingBytes ?? 0;
      if (blePending + lanPending <= blobSendHighWaterBytes) return true;
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return false;
  }

  Future<bool> _waitForReadyLink() async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!_disposed && DateTime.now().isBefore(deadline)) {
      if ((_transport?.hasReadyLinks ?? false) ||
          (_lanTransport?.hasReadyLinks ?? false)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }

  void _notifyTransferProgress() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTransferNotify < 120) return;
    _lastTransferNotify = now;
    notifyListeners();
  }

  Future<void> _retryPending() async {
    if ((_transport == null && _lanTransport == null) || _retryInFlight) return;
    _retryInFlight = true;
    try {
      final now = DateTime.now();
      var changed = false;

      for (final entry in _outbox.entries.toList()) {
        final message = entry.value;
        if (now.difference(message.timestamp) > const Duration(minutes: 5)) {
          message.status = MessageStatus.failed;
          message.transferError = message.isAttachment
              ? 'Transfer expired'
              : message.transferError;
          _outbox.remove(entry.key);
          _attempts.remove(entry.key);
          changed = true;
          continue;
        }

        final attempts = (_attempts[entry.key] ?? 0) + 1;
        _attempts[entry.key] = attempts;
        if (attempts > 8) {
          message.status = MessageStatus.failed;
          message.transferError = message.isAttachment
              ? 'Transfer failed'
              : message.transferError;
          _outbox.remove(entry.key);
          _attempts.remove(entry.key);
          changed = true;
          continue;
        }

        if (await _sendOutboxMessage(message)) {
          changed = true;
        }
      }

      // Large transfers outlive the metadata outbox: the recipient may have
      // acknowledged the descriptor before the blob finished. Keep retrying
      // them while a link exists, with a separate attempt budget.
      final transport = _transport;
      if (transport != null && transport.hasReadyLinks) {
        for (final message in _messages.toList()) {
          if (!message.outgoing || !message.isAttachment) continue;
          if (message.transferProgress >= 1) continue;
          if (message.status == MessageStatus.failed) continue;
          if (_startedBlobTransfers.contains(message.id)) continue;
          final attachment = message.attachment;
          if (attachment == null || attachment.path == null) continue;

          if (now.difference(message.timestamp) > const Duration(minutes: 5)) {
            message.transferError = 'Transfer expired';
            changed = true;
            continue;
          }

          final attempts = (_blobAttempts[message.id] ?? 0) + 1;
          _blobAttempts[message.id] = attempts;
          if (attempts > 8) {
            message.transferError = 'Transfer interrupted';
            changed = true;
            continue;
          }
          unawaited(_startBlobTransfer(message));
          changed = true;
        }
      }

      // Drop abandoned incoming transfers so the bounded buffer cannot fill.
      for (final incoming in _incomingBlobs.values.toList()) {
        if (now.difference(incoming.createdAt) < const Duration(minutes: 10)) {
          continue;
        }
        incoming.message.transferError = 'Transfer expired';
        _incomingBlobs.remove(incoming.key);
        changed = true;
      }

      if (changed) {
        _scheduleSave();
        notifyListeners();
      }
    } finally {
      _retryInFlight = false;
    }
  }

  Future<void> _flushPendingFor(String peerId) async {
    if (_outbox.isEmpty || _transport == null) return;
    var changed = false;
    for (final entry in _outbox.entries.toList()) {
      final message = entry.value;
      if (!message.isBroadcast && message.to != peerId) continue;
      if (await _sendOutboxMessage(message)) {
        changed = true;
      }
    }
    if (changed) {
      _scheduleSave();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Radio events
  // ---------------------------------------------------------------------------

  Future<void> _startTransport() async {
    if (!initialized || _disposed) return;
    if (_transport == null) {
      final transport = BleTransport(
        selfId: peerId,
        selfName: displayName.isEmpty ? 'MGS user' : displayName,
      );
      _transport = transport;
      _radioActive = true;
      _transportSubscription = transport.events.listen(_onBleEvent);
      try {
        await transport.start();
      } catch (error) {
        _addLog('Radio failed to start: $error', BleLogLevel.error);
      }
    }
    if (_lanTransport == null) {
      final lan = LanTransport(
        selfId: peerId,
        selfName: displayName.isEmpty ? 'MGS user' : displayName,
      );
      _lanTransport = lan;
      _lanSubscription = lan.events.listen(_onLanEvent);
      try {
        await lan.start();
      } catch (error) {
        _addLog(
          'LAN/USB transport failed to start: $error',
          BleLogLevel.warning,
        );
      }
    }
    unawaited(_retryPending());
    notifyListeners();
  }

  Future<void> _stopTransport() async {
    final transport = _transport;
    _transport = null;
    final lan = _lanTransport;
    _lanTransport = null;

    _radioActive = false;
    _advertising = false;
    _scanning = false;
    await _transportSubscription?.cancel();
    _transportSubscription = null;
    if (transport != null) await transport.dispose();

    await _lanSubscription?.cancel();
    _lanSubscription = null;
    if (lan != null) await lan.dispose();

    for (final peer in _peers.values) {
      peer.connected = false;
    }
    for (final device in _nearby.values) {
      device.connected = false;
    }
    notifyListeners();
  }

  void _onLanEvent(LanEvent event) {
    if (_disposed) return;
    switch (event) {
      case LanLogEvent():
        _addLog(event.message, event.level);
      case LanStateEvent():
        _localIps = event.localAddresses;
        _usbConnected = event.usbConnected;
        notifyListeners();
      case LanPeerUpEvent():
        final peer = _peers.putIfAbsent(
          event.peerId,
          () => Peer(id: event.peerId, name: event.name),
        );
        peer.name = event.name;
        peer.connected = true;
        peer.connectionType = event.linkType == LanLinkType.usb
            ? PeerConnectionType.usb
            : PeerConnectionType.wifi;
        peer.ipAddress = event.address;
        peer.lastSeen = DateTime.now();

        _addLog(
          '${event.name} connected via ${event.linkType.name.toUpperCase()} (${event.address})',
        );
        unawaited(_flushPendingFor(event.peerId));
        unawaited(_retryPending());
        notifyListeners();
      case LanPeerDownEvent():
        final peer = _peers[event.peerId];
        if (peer != null) {
          final onBle =
              _transport?.connectedPeerIds.contains(event.peerId) ?? false;
          if (!onBle) {
            peer.connected = false;
            peer.lastSeen = DateTime.now();
          } else {
            peer.connectionType = PeerConnectionType.ble;
          }
          peer.ipAddress = null;
        }
        _addLog(
          '${peer?.name ?? shortPeerId(event.peerId)} disconnected from LAN/USB',
          BleLogLevel.warning,
        );
        notifyListeners();
      case LanDataEvent():
        _onData(
          BleDataEvent(
            linkId: event.linkId,
            peerId: event.peerId,
            type: event.type,
            payload: event.payload,
          ),
        );
    }
  }

  Future<bool> connectToIp(String host, {int port = defaultLanPort}) async {
    final lan = _lanTransport;
    if (lan == null) return false;
    _addLog('Connecting to $host:$port…');
    final ok = await lan.connectTo(host, port: port);
    if (ok) {
      _addLog('Connected to $host:$port');
    }
    return ok;
  }

  void _onBleEvent(BleEvent event) {
    if (_disposed) return;
    switch (event) {
      case BleLogEvent():
        _addLog(event.message, event.level);
      case BleStateEvent():
        _bleState = event.state;
        notifyListeners();
      case BleScanEvent():
        _scanning = event.active;
        notifyListeners();
      case BleAdvertisingEvent():
        _advertising = event.active;
        notifyListeners();
      case BleSeenEvent():
        _onSeen(event);
      case BlePeerUpEvent():
        _onPeerUp(event);
      case BlePeerDownEvent():
        _onPeerDown(event);
      case BleDataEvent():
        _onData(event);
    }
  }

  void _onSeen(BleSeenEvent event) {
    final existing = _nearby[event.address];
    _nearby[event.address] = NearbyDevice(
      address: event.address,
      rssi: event.rssi,
      peerId: existing?.peerId,
      name: existing?.name,
      connected: existing?.connected ?? false,
      lastSeen: DateTime.now(),
    );

    final now = DateTime.now();
    if (now.difference(_lastNearbyNotify) > const Duration(milliseconds: 900)) {
      _lastNearbyNotify = now;
      notifyListeners();
    }
  }

  void _onPeerUp(BlePeerUpEvent event) {
    final peer = _peers.putIfAbsent(
      event.peerId,
      () => Peer(id: event.peerId, name: event.name),
    );
    peer.name = event.name;
    peer.connected = true;
    peer.lastSeen = DateTime.now();

    final device = _nearby[event.address];
    if (device != null) {
      device.peerId = event.peerId;
      device.name = event.name;
      device.connected = true;
    }

    _addLog('${event.name} connected');
    unawaited(_flushPendingFor(event.peerId));
    unawaited(_retryPending());
    notifyListeners();
  }

  void _onPeerDown(BlePeerDownEvent event) {
    final peer = _peers[event.peerId];
    if (peer != null) {
      peer.connected = false;
      peer.lastSeen = DateTime.now();
    }
    final device = _nearby[event.address];
    if (device != null) device.connected = false;

    _addLog(
      '${peer?.name ?? shortPeerId(event.peerId)} disconnected',
      BleLogLevel.warning,
    );
    notifyListeners();
  }

  void _onData(BleDataEvent event) {
    _dataQueue = _dataQueue
        .then((_) async {
          if (_disposed) return;
          switch (event.type) {
            case FrameType.message:
              await _handleIncomingMessage(event);
            case FrameType.ack:
              _handleAck(event);
            case FrameType.blob:
              await _handleIncomingBlob(event);
            case FrameType.hello:
            case FrameType.ping:
              break;
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          _addLog('Payload handling failed: $error', BleLogLevel.error);
        });
  }

  Future<void> _handleIncomingMessage(BleDataEvent event) async {
    final router = _router;
    if (router == null) return;

    final result = router.receive(event.payload, viaPeerId: event.peerId);
    if (result.error != null) {
      _addLog('Dropped message: ${result.error}', BleLogLevel.warning);
      return;
    }

    // Acknowledge before the duplicate check so retries can recover a lost ACK.
    if (result.ackMessageId != null) {
      final ackBytes = bytesFromHex(result.ackMessageId!, byteLength: 8);
      if (event.linkId.startsWith('lan:')) {
        _lanTransport?.sendOnLink(event.linkId, FrameType.ack, ackBytes);
      } else {
        _transport?.sendOnLink(event.linkId, FrameType.ack, ackBytes);
      }
    }

    // Relay without needing the passphrase: only the header is inspected.
    final relay = result.relay;
    if (relay != null && relayEnabled) {
      _lanTransport?.broadcast(
        FrameType.message,
        relay,
        excludePeerId: event.peerId,
      );
      _transport?.broadcast(
        FrameType.message,
        relay,
        excludePeerId: event.peerId,
      );
    }

    if (result.duplicate) return;
    final envelope = result.envelope;
    if (envelope == null) return;

    final header = envelope.header;
    Uint8List? plain;
    if (header.encrypted) {
      final cipher = _meshCipher;
      if (cipher == null) {
        _addLog(
          'Encrypted message from ${shortPeerId(header.from)} is locked: '
          'set the mesh passphrase',
          BleLogLevel.warning,
        );
      } else {
        try {
          plain = await cipher.decrypt(envelope.content, aad: envelope.aad);
        } catch (error) {
          _addLog(
            'Cannot decrypt message from ${shortPeerId(header.from)}: $error',
            BleLogLevel.warning,
          );
        }
      }
      if (plain == null) {
        _acceptIncoming(_buildLockedMessage(header));
        return;
      }
    } else {
      plain = envelope.content;
    }

    Message message;
    try {
      message = _buildIncomingMessage(header, plain);
    } catch (error) {
      _addLog('Dropped message body: $error', BleLogLevel.warning);
      return;
    }

    _acceptIncoming(message);
  }

  void _acceptIncoming(Message message) {
    _messages.add(message);
    _outbox.remove(message.id);
    _attempts.remove(message.id);

    if (_activeThreadId != message.threadId) {
      _unread[message.threadId] = (_unread[message.threadId] ?? 0) + 1;
    }

    final peer = _peers.putIfAbsent(
      message.from,
      () => Peer(id: message.from, name: message.fromName),
    );
    peer.name = message.fromName;
    peer.lastSeen = DateTime.now();

    final attachment = message.attachment;
    if (attachment != null && !message.decryptionFailed) {
      _registerIncomingAttachment(message);
    }

    _trimMessages();
    _scheduleSave();
    notifyListeners();
  }

  Message _buildLockedMessage(MessageHeader header) => Message(
    id: header.id,
    from: header.from,
    fromName: header.fromName,
    to: header.to,
    text: '',
    timestampMs: header.timestampMs,
    ttl: header.ttl,
    hops: header.hops,
    outgoing: false,
    status: MessageStatus.received,
    kind: header.kind,
    encrypted: true,
    decryptionFailed: true,
    transferProgress: 1,
  );

  Message _buildIncomingMessage(MessageHeader header, Uint8List plain) {
    var text = '';
    MessageAttachment? attachment;
    if (header.kind == MessageKind.text) {
      text = utf8.decode(plain).trim();
      if (text.isEmpty) {
        throw const FormatException('Message body is empty.');
      }
      if (text.length > maxMessageLength) {
        throw const FormatException('Message is too long.');
      }
    } else {
      final metadata = BlobMetadata.decode(plain);
      if (metadata.kind != header.kind) {
        throw const FormatException('Attachment kind does not match.');
      }
      attachment = metadata.toAttachment();
    }

    return Message(
      id: header.id,
      from: header.from,
      fromName: header.fromName,
      to: header.to,
      text: text,
      timestampMs: header.timestampMs,
      ttl: header.ttl,
      hops: header.hops,
      outgoing: false,
      status: MessageStatus.received,
      kind: header.kind,
      attachment: attachment,
      encrypted: header.encrypted,
      transferProgress: attachment == null ? 1 : 0,
    );
  }

  void _registerIncomingAttachment(Message message) {
    final attachment = message.attachment;
    if (attachment == null) return;

    if (_incomingBlobs.length >= maxIncomingBlobs) {
      final oldest = _incomingBlobs.values.reduce(
        (a, b) => a.createdAt.isBefore(b.createdAt) ? a : b,
      );
      oldest.message.transferError = 'Transfer was interrupted';
      _incomingBlobs.remove(oldest.key);
    }

    _incomingBlobs[attachment.key] = _IncomingBlob(
      key: attachment.key,
      message: message,
      count: attachment.chunkCount,
      totalLength: attachment.cipherBytes,
    );

    unawaited(_resolveExistingAttachment(message));
  }

  Future<void> _resolveExistingAttachment(Message message) async {
    final attachment = message.attachment;
    if (attachment == null) return;
    final path = await _blobs.find(attachment.blobId, attachment.name);
    if (path == null) return;
    attachment.path = path;
    message.transferProgress = 1;
    message.transferError = null;
    _incomingBlobs.remove(attachment.key);
    _scheduleSave();
    notifyListeners();
  }

  Future<void> _handleIncomingBlob(BleDataEvent event) async {
    final router = _router;
    if (router == null) return;

    final result = router.receiveBlob(event.payload);
    if (result.error != null) {
      _addLog('Dropped blob chunk: ${result.error}', BleLogLevel.warning);
      return;
    }

    final relay = result.relay;
    if (relay != null && relayEnabled) {
      _lanTransport?.broadcast(
        FrameType.blob,
        relay,
        excludePeerId: event.peerId,
      );
      _transport?.broadcast(FrameType.blob, relay, excludePeerId: event.peerId);
    }
    if (result.duplicate) return;

    final chunk = result.chunk;
    if (chunk == null) return;
    if (!chunk.isBroadcast && chunk.to != peerId) return;

    final incoming = _incomingBlobs[chunk.key];
    if (incoming == null) return;
    if (chunk.count != incoming.count ||
        chunk.totalLength != incoming.totalLength) {
      _addLog('Blob chunk does not match its descriptor', BleLogLevel.warning);
      return;
    }
    if (incoming.chunks.containsKey(chunk.index)) return;

    incoming.chunks[chunk.index] = chunk.data;
    incoming.bytes += chunk.data.length;
    final message = incoming.message;
    final elapsed =
        DateTime.now().difference(incoming.createdAt).inMilliseconds / 1000.0;
    if (elapsed > 0.15) {
      message.transferSpeed = incoming.bytes / elapsed;
      final remainingBytes = incoming.totalLength - incoming.bytes;
      if (message.transferSpeed > 10) {
        message.transferEtaSeconds = (remainingBytes / message.transferSpeed)
            .ceil();
      }
    }
    message.transferProgress = (incoming.chunks.length / incoming.count) * 0.99;
    _notifyTransferProgress();

    if (incoming.chunks.length == incoming.count) {
      await _finishIncomingBlob(incoming);
    }
  }

  Future<void> _finishIncomingBlob(_IncomingBlob incoming) async {
    final message = incoming.message;
    final attachment = message.attachment;
    if (attachment == null) return;

    try {
      final ciphertext = Uint8List(incoming.totalLength);
      var offset = 0;
      for (var index = 0; index < incoming.count; index++) {
        final chunk = incoming.chunks[index];
        if (chunk == null) {
          throw const FormatException('Blob has missing chunks.');
        }
        ciphertext.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      if (offset != incoming.totalLength) {
        throw const FormatException('Blob length does not match.');
      }

      Uint8List plain;
      if (message.encrypted) {
        final cipher = _meshCipher;
        if (cipher == null) {
          throw const MeshDecryptionException(
            'Set the mesh passphrase to open this attachment.',
          );
        }
        plain = await cipher.decrypt(
          ciphertext,
          aad: blobAad(attachment.blobId, attachment.transferId),
        );
      } else {
        plain = ciphertext;
      }

      if (plain.length != attachment.size) {
        throw const FormatException('Attachment size does not match.');
      }
      final digest = sha256.convert(plain).toString();
      if (digest != attachment.digest) {
        throw const FormatException('Attachment checksum failed.');
      }

      final path = await _blobs.saveBytes(
        blobId: attachment.blobId,
        name: attachment.name,
        bytes: plain,
      );
      attachment.path = path;
      message.transferProgress = 1;
      message.transferSpeed = 0;
      message.transferEtaSeconds = null;
      message.transferError = null;
      _incomingBlobs.remove(incoming.key);
      _addLog('Received ${message.kind.name} ${attachment.name}');
    } catch (error) {
      message.transferError = error is MeshDecryptionException
          ? error.message
          : 'Transfer failed';
      message.transferProgress = 0;
      message.transferSpeed = 0;
      message.transferEtaSeconds = null;
      _incomingBlobs.remove(incoming.key);
      _addLog('Blob receive failed: $error', BleLogLevel.warning);
    }

    _scheduleSave();
    notifyListeners();
  }

  void _handleAck(BleDataEvent event) {
    if (event.payload.length != 8) {
      _addLog('Ignored malformed ACK', BleLogLevel.warning);
      return;
    }
    final id = hexFromBytes(event.payload);
    final message = _messageById(id);
    if (message == null) {
      _outbox.remove(id);
      _attempts.remove(id);
      return;
    }
    message.status = MessageStatus.delivered;
    _outbox.remove(id);
    _attempts.remove(id);
    _scheduleSave();
    notifyListeners();
  }

  Message? _messageById(String id) {
    for (var index = _messages.length - 1; index >= 0; index--) {
      if (_messages[index].id == id) return _messages[index];
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _rebuildPeersFromMessages() {
    for (final message in _messages) {
      if (message.isBroadcast) continue;
      if (message.outgoing) {
        _peers.putIfAbsent(
          message.to,
          () => Peer(id: message.to, name: 'MGS ${shortPeerId(message.to)}'),
        );
      } else {
        _peers.putIfAbsent(
          message.from,
          () => Peer(id: message.from, name: message.fromName),
        );
      }
    }
  }

  void _trimMessages() {
    while (_messages.length > maxStoredMessages) {
      final removed = _messages.removeAt(0);
      _outbox.remove(removed.id);
      _attempts.remove(removed.id);
      final path = removed.attachment?.path;
      if (path != null) unawaited(_blobs.deletePath(path));
    }
  }

  String _normalizeMime(String value) {
    final trimmed = truncateUtf8(value.trim(), maxMimeTypeLength);
    if (trimmed.isEmpty) return 'application/octet-stream';
    return trimmed;
  }

  String _mimeForName(String name) {
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      'md' => 'text/markdown',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'zip' => 'application/zip',
      'apk' => 'application/vnd.android.package-archive',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'wav' => 'audio/wav',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'doc' => 'application/msword',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt' => 'application/vnd.ms-powerpoint',
      'pptx' =>
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      _ => 'application/octet-stream',
    };
  }

  void _addLog(String message, [BleLogLevel level = BleLogLevel.info]) {
    _logs.add(LogLine(message, level));
    while (_logs.length > 120) {
      _logs.removeAt(0);
    }
    if (level != BleLogLevel.info && !_disposed) notifyListeners();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(_saveNow());
    });
  }

  Future<void> _saveNow() async {
    if (!initialized) return;
    if (_saveInFlight) {
      _saveQueued = true;
      return;
    }
    _saveInFlight = true;
    try {
      await _storage.save(
        StoredData(
          peerId: peerId,
          displayName: displayName,
          messages: List<Message>.from(_messages),
          ttl: ttl,
          relayEnabled: relayEnabled,
          radioEnabled: radioEnabled,
          passphrase: passphrase,
        ),
      );
    } catch (error) {
      _addLog('Save failed: $error', BleLogLevel.error);
    } finally {
      _saveInFlight = false;
      if (_saveQueued) {
        _saveQueued = false;
        unawaited(_saveNow());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _retryTimer?.cancel();
    unawaited(_saveNow());
    unawaited(_shutdownTransport());
    super.dispose();
  }

  Future<void> _shutdownTransport() async {
    await _transportSubscription?.cancel();
    _transportSubscription = null;
    await _transport?.dispose();
    _transport = null;

    await _lanSubscription?.cancel();
    _lanSubscription = null;
    await _lanTransport?.dispose();
    _lanTransport = null;
  }
}

class _IncomingBlob {
  _IncomingBlob({
    required this.key,
    required this.message,
    required this.count,
    required this.totalLength,
  }) : createdAt = DateTime.now();

  final String key;
  final Message message;
  final int count;
  final int totalLength;
  final DateTime createdAt;
  final Map<int, Uint8List> chunks = {};
  int bytes = 0;
}

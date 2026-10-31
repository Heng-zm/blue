import 'dart:async';
import 'dart:convert';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/ids.dart';
import '../models/message.dart';
import '../models/peer.dart';
import '../protocol/frame.dart';
import '../protocol/mesh_router.dart';
import '../protocol/wire.dart';
import '../services/ble_transport.dart';
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
  AppController({StorageService? storage})
    : _storage = storage ?? StorageService();

  final StorageService _storage;

  String peerId = '';
  String displayName = '';
  int ttl = defaultTtl;
  bool relayEnabled = true;
  bool radioEnabled = true;
  bool firstRun = true;
  bool initialized = false;
  String? warning;

  MeshRouter? _router;
  BleTransport? _transport;
  StreamSubscription<BleEvent>? _transportSubscription;

  final List<Message> _messages = [];
  final Map<String, Peer> _peers = {};
  final Map<String, NearbyDevice> _nearby = {};
  final List<LogLine> _logs = [];
  final Map<String, int> _unread = {};
  final Map<String, Message> _outbox = {};
  final Map<String, int> _attempts = {};

  BluetoothLowEnergyState _bleState = BluetoothLowEnergyState.unknown;
  bool _advertising = false;
  bool _scanning = false;
  bool _radioActive = false;

  String? _activeThreadId;
  Timer? _saveTimer;
  Timer? _retryTimer;
  bool _saveInFlight = false;
  bool _saveQueued = false;
  bool _booting = false;
  bool _disposed = false;
  DateTime _lastNearbyNotify = DateTime.fromMillisecondsSinceEpoch(0);

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
      _messages.addAll(data.messages);
      // Rebuild the outbox for messages that never left, or that were sent
      // directly but never acknowledged. Old entries expire on the first retry
      // tick rather than flooding the mesh after a long gap.
      for (final message in data.messages) {
        final needsRetry =
            message.outgoing &&
            (message.status == MessageStatus.queued ||
                message.status == MessageStatus.sent);
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
      (_) => _retryPending(),
    );
    notifyListeners();

    if (!firstRun && radioEnabled) {
      unawaited(_startTransport());
    }
    _booting = false;
  }

  Future<void> completeOnboarding(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    displayName = trimmed.length > maxDisplayNameLength
        ? trimmed.substring(0, maxDisplayNameLength)
        : trimmed;
    firstRun = false;
    _router ??= MeshRouter(selfId: peerId, selfName: displayName);
    _router!.selfName = displayName;
    _transport?.setDisplayName(displayName);
    notifyListeners();
    await _saveNow();
    if (radioEnabled) await _startTransport();
  }

  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    displayName = trimmed.length > maxDisplayNameLength
        ? trimmed.substring(0, maxDisplayNameLength)
        : trimmed;
    _router?.selfName = displayName;
    _transport?.setDisplayName(displayName);
    notifyListeners();
    await _saveNow();
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
    _messages.clear();
    _outbox.clear();
    _attempts.clear();
    _unread.clear();
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

  bool sendMessage(String threadId, String text) {
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
      );
    } catch (error) {
      _addLog('Cannot send: $error', BleLogLevel.warning);
      return false;
    }

    _messages.add(message);
    _outbox[message.id] = message;
    _attempts[message.id] = 0;

    if (_sendOutboxMessage(message)) {
      message.status = MessageStatus.sent;
      if (message.isBroadcast) {
        _outbox.remove(message.id);
        _attempts.remove(message.id);
      }
    }

    _trimMessages();
    _scheduleSave();
    notifyListeners();
    return true;
  }

  bool _sendOutboxMessage(Message message) {
    final transport = _transport;
    if (transport == null) return false;
    final payload = encodeJson(message.toWire());

    if (!message.isBroadcast &&
        transport.sendToPeer(message.to, FrameType.message, payload)) {
      return true;
    }
    return transport.broadcast(FrameType.message, payload) > 0;
  }

  void _retryPending() {
    if (_outbox.isEmpty || _transport == null) return;
    final now = DateTime.now();
    var changed = false;

    for (final entry in _outbox.entries.toList()) {
      final message = entry.value;
      if (now.difference(message.timestamp) > const Duration(minutes: 5)) {
        message.status = MessageStatus.failed;
        _outbox.remove(entry.key);
        _attempts.remove(entry.key);
        changed = true;
        continue;
      }

      final attempts = (_attempts[entry.key] ?? 0) + 1;
      _attempts[entry.key] = attempts;
      if (attempts > 8) {
        message.status = MessageStatus.failed;
        _outbox.remove(entry.key);
        _attempts.remove(entry.key);
        changed = true;
        continue;
      }

      if (_sendOutboxMessage(message)) {
        message.status = MessageStatus.sent;
        changed = true;
        if (message.isBroadcast) {
          _outbox.remove(entry.key);
          _attempts.remove(entry.key);
        }
      }
    }

    if (changed) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void _flushPendingFor(String peerId) {
    var changed = false;
    for (final entry in _outbox.entries.toList()) {
      final message = entry.value;
      if (!message.isBroadcast && message.to != peerId) continue;
      if (_sendOutboxMessage(message)) {
        message.status = MessageStatus.sent;
        changed = true;
        if (message.isBroadcast) {
          _outbox.remove(entry.key);
          _attempts.remove(entry.key);
        }
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
    if (_transport != null || !initialized || _disposed) return;
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
    _retryPending();
    notifyListeners();
  }

  Future<void> _stopTransport() async {
    final transport = _transport;
    _transport = null;
    _radioActive = false;
    _advertising = false;
    _scanning = false;
    await _transportSubscription?.cancel();
    _transportSubscription = null;
    if (transport != null) await transport.dispose();
    for (final peer in _peers.values) {
      peer.connected = false;
    }
    for (final device in _nearby.values) {
      device.connected = false;
    }
    notifyListeners();
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
    _flushPendingFor(event.peerId);
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
    if (event.type == FrameType.message) {
      _handleIncomingMessage(event);
    } else if (event.type == FrameType.ack) {
      _handleAck(event);
    }
  }

  void _handleIncomingMessage(BleDataEvent event) {
    final router = _router;
    if (router == null) return;

    Map<String, dynamic> wire;
    try {
      wire = decodeJson(event.payload);
    } catch (error) {
      _addLog('Ignored bad payload: $error', BleLogLevel.warning);
      return;
    }

    final result = router.receive(wire, viaPeerId: event.peerId);
    if (result.error != null) {
      _addLog('Dropped message: ${result.error}', BleLogLevel.warning);
      return;
    }

    // Acknowledge before the duplicate check so retries can recover a lost ACK.
    if (result.ackMessageId != null) {
      _transport?.sendOnLink(
        event.linkId,
        FrameType.ack,
        Uint8List.fromList(utf8.encode(result.ackMessageId!)),
      );
    }

    if (result.duplicate) return;

    final message = result.display;
    if (message != null) {
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

      _trimMessages();
      _scheduleSave();
      notifyListeners();
    }

    final relay = result.relay;
    if (relay != null && relayEnabled) {
      _transport?.broadcast(
        FrameType.message,
        encodeJson(relay),
        excludePeerId: event.peerId,
      );
    }
  }

  void _handleAck(BleDataEvent event) {
    final id = utf8.decode(event.payload, allowMalformed: true);
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
    }
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
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/ids.dart';
import '../protocol/frame.dart';
import '../protocol/wire.dart';

enum BleLogLevel { info, warning, error }

sealed class BleEvent {
  const BleEvent();
}

final class BleLogEvent extends BleEvent {
  const BleLogEvent(this.message, {this.level = BleLogLevel.info});

  final String message;
  final BleLogLevel level;
}

final class BleStateEvent extends BleEvent {
  const BleStateEvent(this.state);

  final BluetoothLowEnergyState state;
}

final class BleScanEvent extends BleEvent {
  const BleScanEvent({required this.active});

  final bool active;
}

final class BleAdvertisingEvent extends BleEvent {
  const BleAdvertisingEvent({required this.active});

  final bool active;
}

final class BleSeenEvent extends BleEvent {
  const BleSeenEvent({required this.address, required this.rssi, this.name});

  final String address;
  final int rssi;
  final String? name;
}

final class BlePeerUpEvent extends BleEvent {
  const BlePeerUpEvent({
    required this.peerId,
    required this.name,
    required this.linkId,
    required this.address,
  });

  final String peerId;
  final String name;
  final String linkId;
  final String address;
}

final class BlePeerDownEvent extends BleEvent {
  const BlePeerDownEvent({
    required this.peerId,
    required this.linkId,
    required this.address,
  });

  final String peerId;
  final String linkId;
  final String address;
}

final class BleDataEvent extends BleEvent {
  const BleDataEvent({
    required this.linkId,
    required this.peerId,
    required this.type,
    required this.payload,
  });

  final String linkId;
  final String peerId;
  final FrameType type;
  final Uint8List payload;
}

/// Runs both BLE roles at once:
///
///  * peripheral: publishes the MGS GATT service and advertises it
///  * central: scans for that service and opens GATT connections
///
/// A connection is only announced after a HELLO exchange, so the rest of the
/// app deals in stable peer ids instead of platform-specific MAC/UUIDs.
class BleTransport {
  BleTransport({
    required this.selfId,
    required String selfName,
    this.maxOutbound = maxOutboundLinks,
  }) : _selfName = selfName;

  final String selfId;
  final int maxOutbound;

  String _selfName;

  CentralManager? _central;
  PeripheralManager? _peripheral;

  final StreamController<BleEvent> _events =
      StreamController<BleEvent>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  final Map<String, _Link> _outbound = {};
  final Map<String, _Link> _inbound = {};
  final Map<String, String> _peerByAddress = {};
  final Set<String> _ignoredAddresses = {};
  final Map<String, DateTime> _lastSeenAt = {};
  final Map<String, DateTime> _lastDialAt = {};
  final Map<String, DateTime> _dialBlockedUntil = {};
  final Map<String, Timer> _dialTimers = {};
  final Set<String> _connecting = {};

  GATTCharacteristic? _localRx;
  GATTCharacteristic? _localTx;

  Timer? _heartbeatTimer;
  Timer? _scanRetryTimer;
  Timer? _advertiseRetryTimer;

  bool _started = false;
  bool _disposed = false;
  bool _poweredOn = false;
  bool _advertising = false;
  bool _scanning = false;
  bool _servicesReady = false;
  bool _authorizing = false;
  int _advertiseFailures = 0;

  Stream<BleEvent> get events => _events.stream;

  bool get advertising => _advertising;
  bool get scanning => _scanning;

  Iterable<String> get connectedPeerIds => _allLinks()
      .where((link) => link.ready && !link.closed && link.peerId != null)
      .map((link) => link.peerId!);

  String get displayName => _selfName;

  void setDisplayName(String name) {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) _selfName = trimmed;
  }

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    final central = CentralManager();
    final peripheral = PeripheralManager();
    _central = central;
    _peripheral = peripheral;

    _subscriptions.add(central.stateChanged.listen(_onCentralState));
    _subscriptions.add(central.discovered.listen(_onDiscovered));
    _subscriptions.add(central.connectionStateChanged.listen(_onOutboundState));
    _subscriptions.add(central.characteristicNotified.listen(_onNotified));

    _subscriptions.add(peripheral.stateChanged.listen(_onPeripheralState));
    _subscriptions.add(
      peripheral.connectionStateChanged.listen(_onInboundState),
    );
    _subscriptions.add(
      peripheral.characteristicWriteRequested.listen(
        (event) => unawaited(_onWriteRequested(event)),
      ),
    );
    _subscriptions.add(
      peripheral.characteristicNotifyStateChanged.listen(
        (event) => unawaited(_onNotifyStateChanged(event)),
      ),
    );

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => _heartbeat(),
    );

    final state = central.state;
    _poweredOn = state == BluetoothLowEnergyState.poweredOn;
    _emit(BleStateEvent(state));

    if (state == BluetoothLowEnergyState.unauthorized && Platform.isAndroid) {
      await _authorize();
    }
    if (_poweredOn) {
      await _startAdvertising();
      await _startScan();
    } else {
      _log('Bluetooth state: ${state.name}');
    }
  }

  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _scanRetryTimer?.cancel();
    _scanRetryTimer = null;
    _advertiseRetryTimer?.cancel();
    _advertiseRetryTimer = null;
    for (final timer in _dialTimers.values) {
      timer.cancel();
    }
    _dialTimers.clear();

    try {
      await _central?.stopDiscovery();
    } catch (_) {
      // Already stopped.
    }
    try {
      await _peripheral?.stopAdvertising();
    } catch (_) {
      // Already stopped.
    }

    _closeAll('radio stopped', notify: false);
    _scanning = false;
    _advertising = false;
    _servicesReady = false;
    _emit(BleScanEvent(active: false));
    _emit(BleAdvertisingEvent(active: false));

    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _central = null;
    _peripheral = null;
    _localRx = null;
    _localTx = null;
    _started = false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _events.close();
  }

  Future<void> pauseScanning() async {
    _scanRetryTimer?.cancel();
    _scanRetryTimer = null;
    try {
      await _central?.stopDiscovery();
    } catch (_) {
      // Already stopped.
    }
    if (_scanning) {
      _scanning = false;
      _emit(BleScanEvent(active: false));
    }
  }

  Future<void> resumeScanning() async {
    if (!_started || _disposed) return;

    // The user may have granted a permission in system settings while the app
    // was away. Permissions do not produce Bluetooth state events, so re-check
    // and recover the radio here. Do not prompt again on every resume; the
    // earlier denial already opened the app settings screen.
    if (Platform.isAndroid) {
      final state = _central?.state ?? BluetoothLowEnergyState.unknown;
      if (state != BluetoothLowEnergyState.poweredOn) return;
      if (!_poweredOn) _emit(BleStateEvent(state));
      _poweredOn = true;
      unawaited(_startAdvertising());
    }

    await _startScan();
  }

  Future<void> showAppSettings() async {
    try {
      await _central?.showAppSettings();
    } catch (_) {
      // Not implemented on every platform.
    }
  }

  bool sendToPeer(String peerId, FrameType type, Uint8List payload) {
    final link = _readyLinkForPeer(peerId);
    if (link == null) return false;
    _enqueue(link, type, payload);
    return true;
  }

  bool sendOnLink(String linkId, FrameType type, Uint8List payload) {
    final link = _linkById(linkId);
    if (link == null || link.closed || !link.ready) return false;
    _enqueue(link, type, payload);
    return true;
  }

  /// Floods [payload] to every ready link. Returns how many links accepted it.
  int broadcast(FrameType type, Uint8List payload, {String? excludePeerId}) {
    var count = 0;
    final usedPeers = <String>{};
    for (final link in _allLinks()) {
      if (link.closed || !link.ready) continue;
      final peerId = link.peerId;
      if (peerId == null) continue;
      if (excludePeerId != null && peerId == excludePeerId) continue;
      if (!usedPeers.add(peerId)) continue;
      _enqueue(link, type, payload);
      count++;
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // Radio setup
  // ---------------------------------------------------------------------------

  Future<void> _authorize() async {
    if (_authorizing || _disposed || !Platform.isAndroid) return;
    _authorizing = true;
    try {
      final central = _central;
      final peripheral = _peripheral;

      // Android splits the nearby-devices permissions between the two roles:
      // central asks for SCAN + CONNECT, peripheral for ADVERTISE + CONNECT.
      // Both managers use the same request code, so the requests must never
      // overlap or the first result is lost and its future never completes.
      final scanGranted = await central?.authorize() ?? false;
      _log(
        scanGranted
            ? 'Bluetooth scan permission granted'
            : 'Bluetooth scan permission denied',
        level: scanGranted ? BleLogLevel.info : BleLogLevel.warning,
      );

      if (!scanGranted) {
        try {
          await central?.showAppSettings();
        } catch (_) {
          // Not supported on every platform.
        }
        return;
      }

      // The second dialog is normally suppressed because CONNECT is already
      // granted and Android auto-grants permissions in the same group.
      final advertiseGranted = await peripheral?.authorize() ?? false;
      _log(
        advertiseGranted
            ? 'Bluetooth advertising permission granted'
            : 'Bluetooth advertising permission denied',
        level: advertiseGranted ? BleLogLevel.info : BleLogLevel.warning,
      );

      if (!advertiseGranted) {
        try {
          await central?.showAppSettings();
        } catch (_) {
          // Not supported on every platform.
        }
        return;
      }

      // Granting permissions does not emit a Bluetooth state event, so refresh
      // the state here and bring the radio up without waiting for a restart.
      final state = central?.state ?? BluetoothLowEnergyState.unknown;
      _poweredOn = state == BluetoothLowEnergyState.poweredOn;
      _emit(BleStateEvent(state));
      if (_poweredOn) {
        await _startAdvertising();
        await _startScan();
      }
    } catch (error) {
      _log('Permission request failed: $error', level: BleLogLevel.error);
    } finally {
      _authorizing = false;
    }
  }

  void _onCentralState(BluetoothLowEnergyStateChangedEventArgs event) {
    final state = event.state;
    _emit(BleStateEvent(state));

    if (state == BluetoothLowEnergyState.unauthorized) {
      if (Platform.isAndroid) unawaited(_authorize());
      _poweredOn = false;
      return;
    }

    _poweredOn = state == BluetoothLowEnergyState.poweredOn;
    if (_poweredOn) {
      unawaited(_startAdvertising());
      unawaited(_startScan());
      return;
    }

    if (state == BluetoothLowEnergyState.poweredOff ||
        state == BluetoothLowEnergyState.unsupported) {
      _servicesReady = false;
      _advertising = false;
      _scanning = false;
      _emit(BleAdvertisingEvent(active: false));
      _emit(BleScanEvent(active: false));
      _closeAll('bluetooth ${state.name}');
    }
  }

  void _onPeripheralState(BluetoothLowEnergyStateChangedEventArgs event) {
    if (event.state == BluetoothLowEnergyState.unauthorized &&
        Platform.isAndroid) {
      unawaited(_authorize());
    } else if (event.state == BluetoothLowEnergyState.poweredOff) {
      _advertising = false;
      _emit(BleAdvertisingEvent(active: false));
    }
  }

  Future<void> _startAdvertising() async {
    if (_disposed || _advertising) return;
    final peripheral = _peripheral;
    if (peripheral == null) return;
    if (!_poweredOn && peripheral.state != BluetoothLowEnergyState.poweredOn) {
      return;
    }

    try {
      if (!_servicesReady) {
        try {
          await peripheral.removeAllServices();
        } catch (_) {
          // Some backends fail when there is nothing to remove.
        }

        final rx = GATTCharacteristic.mutable(
          uuid: mgsRxUuid,
          properties: [
            GATTCharacteristicProperty.read,
            GATTCharacteristicProperty.notify,
          ],
          permissions: [GATTCharacteristicPermission.read],
          descriptors: const [],
        );
        final tx = GATTCharacteristic.mutable(
          uuid: mgsTxUuid,
          properties: [
            GATTCharacteristicProperty.write,
            GATTCharacteristicProperty.writeWithoutResponse,
          ],
          permissions: [GATTCharacteristicPermission.write],
          descriptors: const [],
        );
        final service = GATTService(
          uuid: mgsServiceUuid,
          isPrimary: true,
          includedServices: const [],
          characteristics: [rx, tx],
        );

        await peripheral.addService(service);
        _localRx = rx;
        _localTx = tx;
        _servicesReady = true;
      }

      // A 128-bit service UUID plus a short name fits inside the legacy
      // 31-byte advertisement on every platform we target.
      final advertisement = Advertisement(
        name: Platform.isWindows ? null : 'MGS',
        serviceUUIDs: [mgsServiceUuid],
      );
      await peripheral.startAdvertising(advertisement);

      _advertising = true;
      _advertiseFailures = 0;
      _emit(BleAdvertisingEvent(active: true));
      _log('Advertising MGS service');
    } catch (error) {
      _advertising = false;
      _emit(BleAdvertisingEvent(active: false));
      if (_advertiseFailures == 0 || _advertiseFailures % 5 == 0) {
        _log('Advertising failed: $error', level: BleLogLevel.warning);
      }
      _advertiseFailures++;
      _advertiseRetryTimer?.cancel();
      _advertiseRetryTimer = Timer(const Duration(seconds: 6), () {
        unawaited(_startAdvertising());
      });
    }
  }

  Future<void> _startScan() async {
    if (_disposed || _scanning) return;
    final central = _central;
    if (central == null) return;
    if (!_poweredOn && central.state != BluetoothLowEnergyState.poweredOn) {
      return;
    }

    try {
      await central.startDiscovery(serviceUUIDs: [mgsServiceUuid]);
      _scanning = true;
      _emit(BleScanEvent(active: true));
      _log('Scanning for nearby MGS devices');
    } catch (error) {
      _scanning = false;
      _emit(BleScanEvent(active: false));
      _log('Scan failed: $error', level: BleLogLevel.warning);
      _scanRetryTimer?.cancel();
      _scanRetryTimer = Timer(const Duration(seconds: 6), () {
        unawaited(_startScan());
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Discovery and outbound connections
  // ---------------------------------------------------------------------------

  void _onDiscovered(DiscoveredEventArgs event) {
    if (_disposed || !_poweredOn) return;

    final peripheral = event.peripheral;
    final address = peripheral.uuid.toString();
    final now = DateTime.now();

    // Some adapters hear their own advertisement. Learning our own peer id
    // blacklists the address so we never dial ourselves in a loop.
    if (_ignoredAddresses.contains(address)) return;

    final last = _lastSeenAt[address];
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 700)) {
      return;
    }
    _lastSeenAt[address] = now;

    _emit(
      BleSeenEvent(
        address: address,
        rssi: event.rssi,
        name: event.advertisement.name,
      ),
    );

    _maybeDial(address, peripheral, now);
  }

  void _maybeDial(String address, Peripheral peripheral, DateTime now) {
    if (_connecting.contains(address) || _dialTimers.containsKey(address)) {
      return;
    }
    final existing = _outbound[address];
    if (existing != null && !existing.closed) return;

    final knownPeer = _peerByAddress[address];
    if (knownPeer != null) {
      if (knownPeer == selfId) return;
      if (_linkForPeer(knownPeer) != null) return;
    }

    if (_outbound.length + _connecting.length >= maxOutbound) return;

    final blocked = _dialBlockedUntil[address];
    if (blocked != null && blocked.isAfter(now)) return;

    final lastDial = _lastDialAt[address];
    if (lastDial != null &&
        now.difference(lastDial) < const Duration(seconds: 4)) {
      return;
    }

    _lastDialAt[address] = now;
    _connecting.add(address);

    final delay = Duration(milliseconds: 250 + Random().nextInt(750));
    _dialTimers[address] = Timer(delay, () {
      _dialTimers.remove(address);
      unawaited(_dial(address, peripheral));
    });
  }

  Future<void> _dial(String address, Peripheral peripheral) async {
    final central = _central;
    if (central == null || _disposed || !_poweredOn) {
      _connecting.remove(address);
      return;
    }
    if (_outbound.containsKey(address)) {
      _connecting.remove(address);
      return;
    }

    final link = _Link.outbound(address: address, peripheral: peripheral);
    _outbound[address] = link;

    try {
      _log('Connecting to ${_shortAddress(address)}…');
      await central.connect(peripheral).timeout(const Duration(seconds: 10));
      if (link.closed) return;

      if (Platform.isAndroid) {
        try {
          await central.requestMTU(peripheral, mtu: 517);
        } catch (_) {
          // Older Android versions or a stubborn peer: keep the default MTU.
        }
      }
      if (link.closed) return;

      final services = await central.discoverGATT(peripheral);
      final service = _findService(services);
      if (service == null) {
        throw StateError('MGS GATT service not found');
      }
      final rx = _findCharacteristic(service, mgsRxUuid);
      final tx = _findCharacteristic(service, mgsTxUuid);
      if (rx == null || tx == null) {
        throw StateError('MGS GATT characteristics not found');
      }
      link.rx = rx;
      link.tx = tx;

      var maxWrite = 20;
      try {
        maxWrite = await central.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        );
      } catch (_) {
        // Keep the conservative default.
      }
      link.maxChunkSize = _chunkSizeFor(maxWrite);

      await central.setCharacteristicNotifyState(peripheral, rx, state: true);
      link.subscribed = true;
      if (link.closed) return;

      _log(
        'Subscribed to ${_shortAddress(address)} '
        '(chunk ${link.maxChunkSize} B)',
      );
      _sendHello(link);
    } catch (error) {
      _log('Connection failed: $error', level: BleLogLevel.warning);
      _dialBlockedUntil[address] = DateTime.now().add(
        const Duration(seconds: 6),
      );
      _closeLink(link, 'connect failed', notify: false);
    } finally {
      _connecting.remove(address);
    }
  }

  void _onOutboundState(PeripheralConnectionStateChangedEventArgs event) {
    final link = _outbound[event.peripheral.uuid.toString()];
    if (link == null) return;
    if (event.state == ConnectionState.disconnected) {
      _closeLink(link, 'disconnected');
    }
  }

  void _onInboundState(CentralConnectionStateChangedEventArgs event) {
    final link = _inbound[event.central.uuid.toString()];
    if (link == null) return;
    if (event.state == ConnectionState.disconnected) {
      _closeLink(link, 'central disconnected');
    }
  }

  // ---------------------------------------------------------------------------
  // Inbound GATT and framing
  // ---------------------------------------------------------------------------

  void _onNotified(GATTCharacteristicNotifiedEventArgs event) {
    if (event.characteristic.uuid != mgsRxUuid) return;
    final link = _outbound[event.peripheral.uuid.toString()];
    if (link == null || link.closed) return;
    _handleIncoming(link, event.value);
  }

  Future<void> _onWriteRequested(
    GATTCharacteristicWriteRequestedEventArgs event,
  ) async {
    final peripheral = _peripheral;
    if (peripheral == null) return;

    // Always answer the ATT request, otherwise the central's write hangs.
    try {
      await peripheral.respondWriteRequest(event.request);
    } catch (error) {
      _log('Write response failed: $error', level: BleLogLevel.warning);
    }

    if (event.characteristic.uuid != mgsTxUuid) return;
    if (event.request.offset != 0) {
      _log('Ignoring fragmented long write', level: BleLogLevel.warning);
      return;
    }

    final localRx = _localRx;
    if (localRx == null) return;
    final address = event.central.uuid.toString();
    final link = _inbound.putIfAbsent(
      address,
      () => _Link.inbound(
        address: address,
        central: event.central,
        notifyCharacteristic: localRx,
        writeCharacteristic: event.characteristic,
      ),
    );
    _handleIncoming(link, event.request.value);
  }

  Future<void> _onNotifyStateChanged(
    GATTCharacteristicNotifyStateChangedEventArgs event,
  ) async {
    if (event.characteristic.uuid != mgsRxUuid) return;
    final address = event.central.uuid.toString();
    var link = _inbound[address];

    if (link == null) {
      final rx = _localRx;
      final tx = _localTx;
      if (rx == null || tx == null) return;
      link = _Link.inbound(
        address: address,
        central: event.central,
        notifyCharacteristic: rx,
        writeCharacteristic: tx,
      );
      _inbound[address] = link;
    }

    if (!event.state) {
      _closeLink(link, 'notifications disabled');
      return;
    }

    link.subscribed = true;
    link.lastActivity = DateTime.now();
    try {
      final maxNotify = await _peripheral?.getMaximumNotifyLength(
        event.central,
      );
      if (maxNotify != null) {
        link.maxChunkSize = _chunkSizeFor(maxNotify);
      }
    } catch (_) {
      // Keep the default chunk size.
    }
    _sendHello(link);
  }

  void _handleIncoming(_Link link, Uint8List value) {
    link.lastActivity = DateTime.now();

    final frame = Frame.tryDecode(value);
    if (frame == null) {
      _log('Dropped malformed BLE frame', level: BleLogLevel.warning);
      return;
    }

    final assembled = link.assembler.add(frame);
    if (assembled == null) return;

    switch (assembled.type) {
      case FrameType.hello:
        _handleHello(link, assembled.payload);
      case FrameType.ping:
        break;
      case FrameType.message:
      case FrameType.ack:
        final peerId = link.peerId;
        if (!link.ready || peerId == null) return;
        _emit(
          BleDataEvent(
            linkId: link.id,
            peerId: peerId,
            type: assembled.type,
            payload: assembled.payload,
          ),
        );
    }
  }

  void _handleHello(_Link link, Uint8List payload) {
    try {
      final json = decodeJson(payload);
      final version = json['v'];
      final rawId = json['id'];
      final rawName = json['name'];
      if (version != protocolVersion || rawId is! String || !isPeerId(rawId)) {
        throw const FormatException('Invalid HELLO');
      }

      if (rawId == selfId) {
        _ignoredAddresses.add(link.address);
        _closeLink(link, 'loopback connection', notify: false);
        return;
      }

      final rawTrimmed = rawName is String ? rawName.trim() : '';
      final name = rawTrimmed.isEmpty
          ? 'MGS ${shortPeerId(rawId)}'
          : rawTrimmed.substring(
              0,
              min(rawTrimmed.length, maxDisplayNameLength),
            );

      link.peerId = rawId;
      link.peerName = name;
      _peerByAddress[link.address] = rawId;

      final existing = _readyLinkForPeer(rawId);
      if (existing != null && existing != link) {
        final preferOutbound = selfId.compareTo(rawId) < 0;
        final keepNew = link.outboundRole == preferOutbound;
        if (!keepNew) {
          _closeLink(link, 'duplicate link', notify: false);
          return;
        }
        _closeLink(existing, 'duplicate link', notify: false);
      }

      if (link.closed) return;
      link.ready = true;
      _emit(
        BlePeerUpEvent(
          peerId: rawId,
          name: name,
          linkId: link.id,
          address: link.address,
        ),
      );
      _log('Linked with $name (${shortPeerId(rawId)})');
    } catch (error) {
      _log('Handshake failed: $error', level: BleLogLevel.warning);
      _closeLink(link, 'bad handshake', notify: false);
    }
  }

  void _sendHello(_Link link) {
    try {
      final payload = encodeJson(<String, dynamic>{
        'v': protocolVersion,
        'id': selfId,
        'name': _selfName,
        'os': Platform.operatingSystem,
      });
      _enqueue(link, FrameType.hello, payload);
    } catch (error) {
      _log('Could not send HELLO: $error', level: BleLogLevel.error);
      _closeLink(link, 'hello failed');
    }
  }

  void _enqueue(_Link link, FrameType type, Uint8List payload) {
    if (link.closed) return;

    List<Frame> frames;
    try {
      frames = buildFrames(
        type: type,
        payload: payload,
        maxChunkSize: link.maxChunkSize,
      );
    } catch (error) {
      _log('Cannot frame payload: $error', level: BleLogLevel.warning);
      return;
    }

    link.queue = link.queue
        .then((_) async {
          for (final frame in frames) {
            if (link.closed) return;
            final bytes = frame.encode();

            if (link.outboundRole) {
              final central = _central;
              final peripheral = link.peripheral;
              final tx = link.tx;
              if (central == null || peripheral == null || tx == null) return;
              await central.writeCharacteristic(
                peripheral,
                tx,
                value: bytes,
                type: GATTCharacteristicWriteType.withResponse,
              );
            } else {
              final peripheralManager = _peripheral;
              final central = link.central;
              final characteristic = link.notifyCharacteristic;
              if (peripheralManager == null ||
                  central == null ||
                  characteristic == null) {
                return;
              }
              await peripheralManager.notifyCharacteristic(
                central,
                characteristic,
                value: bytes,
              );
            }
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          _log('Send failed: $error', level: BleLogLevel.warning);
          _closeLink(link, 'write failed');
        });
  }

  // ---------------------------------------------------------------------------
  // Link bookkeeping
  // ---------------------------------------------------------------------------

  void _heartbeat() {
    if (_disposed) return;
    final now = DateTime.now();
    for (final link in _allLinks()) {
      if (link.closed) continue;

      if (!link.ready &&
          now.difference(link.createdAt) > const Duration(seconds: 20)) {
        _closeLink(link, 'handshake timeout');
        continue;
      }
      if (link.ready &&
          now.difference(link.lastActivity) > const Duration(seconds: 60)) {
        _closeLink(link, 'heartbeat timeout');
        continue;
      }
      if (link.ready) {
        _enqueue(link, FrameType.ping, Uint8List(0));
      }
    }
  }

  void _closeLink(_Link link, String reason, {bool notify = true}) {
    if (link.closed) return;
    link.closed = true;
    final wasReady = link.ready;
    link.ready = false;
    link.assembler.clear();

    if (link.outboundRole) {
      _outbound.remove(link.address);
      final peripheral = link.peripheral;
      if (peripheral != null) {
        unawaited(_disconnectPeripheral(peripheral));
      }
    } else {
      _inbound.remove(link.address);
      if (Platform.isAndroid) {
        final central = link.central;
        if (central != null) {
          unawaited(_disconnectCentral(central));
        }
      }
    }

    final peerId = link.peerId;
    if (wasReady && peerId != null && _readyLinkForPeer(peerId) == null) {
      if (notify) {
        _emit(
          BlePeerDownEvent(
            peerId: peerId,
            linkId: link.id,
            address: link.address,
          ),
        );
        _log(
          'Disconnected from ${link.peerName ?? shortPeerId(peerId)} ($reason)',
          level: BleLogLevel.warning,
        );
      }
    } else if (!wasReady && reason != 'duplicate link') {
      _log('Link closed: $reason', level: BleLogLevel.info);
    }
  }

  void _closeAll(String reason, {bool notify = true}) {
    for (final link in _allLinks()) {
      _closeLink(link, reason, notify: notify);
    }
  }

  Future<void> _disconnectPeripheral(Peripheral peripheral) async {
    try {
      await _central?.disconnect(peripheral);
    } catch (_) {
      // Already gone.
    }
  }

  Future<void> _disconnectCentral(Central central) async {
    try {
      await _peripheral?.disconnect(central);
    } catch (_) {
      // Already gone.
    }
  }

  List<_Link> _allLinks() => <_Link>[..._outbound.values, ..._inbound.values];

  _Link? _readyLinkForPeer(String peerId) {
    for (final link in _allLinks()) {
      if (!link.closed && link.ready && link.peerId == peerId) return link;
    }
    return null;
  }

  _Link? _linkForPeer(String peerId) {
    for (final link in _allLinks()) {
      if (!link.closed && link.peerId == peerId) return link;
    }
    return null;
  }

  _Link? _linkById(String linkId) {
    final separator = linkId.indexOf(':');
    if (separator <= 0) return null;
    final role = linkId.substring(0, separator);
    final address = linkId.substring(separator + 1);
    return (role == 'o' ? _outbound : _inbound)[address];
  }

  GATTService? _findService(List<GATTService> services) {
    for (final service in services) {
      if (service.uuid == mgsServiceUuid) return service;
    }
    return null;
  }

  GATTCharacteristic? _findCharacteristic(GATTService service, UUID uuid) {
    for (final characteristic in service.characteristics) {
      if (characteristic.uuid == uuid) return characteristic;
    }
    return null;
  }

  int _chunkSizeFor(int maxLength) {
    final usable = maxLength - frameHeaderLength;
    if (usable <= 8) return 8;
    return usable > maxChunkPayloadBytes ? maxChunkPayloadBytes : usable;
  }

  String _shortAddress(String address) {
    final clean = address.replaceAll(':', '').replaceAll('-', '');
    if (clean.length <= 6) return clean;
    return clean.substring(clean.length - 6);
  }

  void _emit(BleEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _log(String message, {BleLogLevel level = BleLogLevel.info}) {
    debugPrint('[MGS] $message');
    _emit(BleLogEvent(message, level: level));
  }
}

class _Link {
  _Link.outbound({required this.address, required this.peripheral})
    : outboundRole = true,
      central = null,
      notifyCharacteristic = null,
      writeCharacteristic = null;

  _Link.inbound({
    required this.address,
    required this.central,
    required this.notifyCharacteristic,
    required this.writeCharacteristic,
  }) : outboundRole = false,
       peripheral = null;

  final String address;
  final bool outboundRole;
  final Peripheral? peripheral;
  final Central? central;
  GATTCharacteristic? rx;
  GATTCharacteristic? tx;
  final GATTCharacteristic? notifyCharacteristic;
  final GATTCharacteristic? writeCharacteristic;

  String? peerId;
  String? peerName;
  bool ready = false;
  bool subscribed = false;
  bool closed = false;
  int maxChunkSize = 20;
  final DateTime createdAt = DateTime.now();
  DateTime lastActivity = DateTime.now();
  final FrameAssembler assembler = FrameAssembler();
  Future<void> queue = Future<void>.value();

  String get id => '${outboundRole ? 'o' : 'i'}:$address';
}

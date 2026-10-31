import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../protocol/frame.dart';
import 'ble_transport.dart' show BleLogLevel;

enum LanLinkType { wifi, usb, lan }

sealed class LanEvent {
  const LanEvent();
}

final class LanLogEvent extends LanEvent {
  const LanLogEvent(this.message, {this.level = BleLogLevel.info});

  final String message;
  final BleLogLevel level;
}

final class LanStateEvent extends LanEvent {
  const LanStateEvent({
    required this.active,
    required this.port,
    required this.localAddresses,
    this.usbConnected = false,
  });

  final bool active;
  final int port;
  final List<String> localAddresses;
  final bool usbConnected;
}

final class LanPeerUpEvent extends LanEvent {
  const LanPeerUpEvent({
    required this.peerId,
    required this.name,
    required this.linkId,
    required this.address,
    required this.linkType,
  });

  final String peerId;
  final String name;
  final String linkId;
  final String address;
  final LanLinkType linkType;
}

final class LanPeerDownEvent extends LanEvent {
  const LanPeerDownEvent({
    required this.peerId,
    required this.linkId,
    required this.address,
  });

  final String peerId;
  final String linkId;
  final String address;
}

final class LanDataEvent extends LanEvent {
  const LanDataEvent({
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

const int defaultLanPort = 52525;
final Uint8List _beaconMagic = Uint8List.fromList([
  0x4D,
  0x47,
  0x53,
  0x31,
]); // 'MGS1'

class LanTransport {
  LanTransport({
    required this.selfId,
    required String selfName,
    this.port = defaultLanPort,
    this.autoProbe = true,
  }) : _selfName = selfName;

  final String selfId;
  final int port;
  final bool autoProbe;

  String _selfName;
  bool _started = false;
  bool _disposed = false;
  int _actualPort = defaultLanPort;

  ServerSocket? _server;
  RawDatagramSocket? _beaconRx;
  RawDatagramSocket? _beaconTx;

  Timer? _beaconTimer;
  Timer? _usbProbeTimer;

  final Map<String, _LanLink> _links = {};
  final Set<String> _connectingHosts = {};
  final StreamController<LanEvent> _events =
      StreamController<LanEvent>.broadcast();

  final FrameAssembler _assembler = FrameAssembler();

  Stream<LanEvent> get events => _events.stream;

  bool get hasReadyLinks =>
      _links.values.any((link) => link.ready && !link.closed);

  int get pendingBytes =>
      _links.values.fold(0, (sum, link) => sum + link.pendingBytes);

  Iterable<String> get connectedPeerIds => _links.values
      .where((l) => l.ready && !l.closed && l.peerId != null)
      .map((l) => l.peerId!);

  String get displayName => _selfName;

  void setDisplayName(String name) {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) _selfName = trimmed;
  }

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    await _startServer();
    await _startBeaconListener();
    await _startBeaconBroadcaster();

    if (autoProbe) {
      _beaconTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        _sendDiscoveryBeacon().catchError((_) {});
      });
      _usbProbeTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _probeUsbLinks().catchError((_) {});
      });
    }

    _notifyState();
    _events.add(LanLogEvent('LAN & USB mesh active on port $_actualPort'));
  }

  Future<void> _startServer() async {
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );
      _actualPort = _server!.port;
    } catch (_) {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
        _actualPort = _server!.port;
      } catch (e) {
        _events.add(
          LanLogEvent(
            'Could not bind LAN server: $e',
            level: BleLogLevel.warning,
          ),
        );
        return;
      }
    }

    _server?.listen(
      _onIncomingSocket,
      onError: (e) {
        _events.add(
          LanLogEvent('LAN server error: $e', level: BleLogLevel.warning),
        );
      },
    );
  }

  Future<void> _startBeaconListener() async {
    try {
      _beaconRx = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      _beaconRx?.broadcastEnabled = true;
      _beaconRx?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _beaconRx?.receive();
          if (datagram != null) _handleBeacon(datagram);
        }
      });
    } catch (_) {
      // Receiver port might be locked on some OS variants; broadcast sender still works.
    }
  }

  Future<void> _startBeaconBroadcaster() async {
    try {
      _beaconTx = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      _beaconTx?.broadcastEnabled = true;
    } catch (_) {}
  }

  void _handleBeacon(Datagram datagram) {
    final data = datagram.data;
    if (data.length < 24) return;
    // Check magic 'MGS1'
    if (data[0] != _beaconMagic[0] ||
        data[1] != _beaconMagic[1] ||
        data[2] != _beaconMagic[2] ||
        data[3] != _beaconMagic[3]) {
      return;
    }

    final peerId = ascii.decode(data.sublist(4, 20), allowInvalid: true);
    if (peerId == selfId) return; // Ignore own beacon

    final view = ByteData.sublistView(data);
    final peerPort = view.getUint16(20, Endian.big);
    final nameLen = data[23];
    final peerName = (data.length >= 24 + nameLen)
        ? utf8.decode(data.sublist(24, 24 + nameLen), allowMalformed: true)
        : 'Peer $peerId';

    final remoteIp = datagram.address.address;

    // Check if already connected to this peer
    for (final link in _links.values) {
      if (link.peerId == peerId && !link.closed) return;
    }

    // Tie-breaker to prevent dual-dial race conditions
    if (selfId.compareTo(peerId) < 0) {
      unawaited(
        connectTo(
          remoteIp,
          port: peerPort,
          expectedPeerId: peerId,
          expectedName: peerName,
        ),
      );
    }
  }

  Future<void> _sendDiscoveryBeacon() async {
    if (_disposed || !_started || _beaconTx == null) return;

    final nameBytes = utf8.encode(_selfName);
    final clampedNameLen = min(nameBytes.length, 255);
    final packet = Uint8List(24 + clampedNameLen);

    packet.setRange(0, 4, _beaconMagic);
    packet.setRange(4, 20, ascii.encode(selfId.padRight(16).substring(0, 16)));

    final view = ByteData.sublistView(packet);
    view.setUint16(20, _actualPort, Endian.big);
    packet[22] = 0; // Hint: any
    packet[23] = clampedNameLen;
    packet.setRange(
      24,
      24 + clampedNameLen,
      nameBytes.sublist(0, clampedNameLen),
    );

    // Send to global IPv4 broadcast
    try {
      _beaconTx?.send(
        packet,
        InternetAddress('255.255.255.255'),
        defaultLanPort,
      );
    } catch (_) {}

    // Also send on each network interface broadcast
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('127.')) continue;
          final lastDot = ip.lastIndexOf('.');
          if (lastDot > 0) {
            final subnetBroadcast = '${ip.substring(0, lastDot)}.255';
            try {
              _beaconTx?.send(
                packet,
                InternetAddress(subnetBroadcast),
                defaultLanPort,
              );
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  /// Automatically probes well-known USB tethering gateways and ADB loopback.
  Future<void> _probeUsbLinks() async {
    if (_disposed || !_started) return;

    final targets = <String>[
      '127.0.0.1', // ADB port forwarding (adb forward tcp:52525 tcp:52525)
      '192.168.42.1', // Android USB tethering gateway
      '192.168.42.2',
      '192.168.43.1', // Hotspot / USB tethering
      '192.168.137.1', // Windows ICS tethering gateway
    ];

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        final isUsb =
            name.contains('rndis') ||
            name.contains('usb') ||
            name.contains('ncm');
        if (isUsb) {
          for (final addr in iface.addresses) {
            final ip = addr.address;
            final lastDot = ip.lastIndexOf('.');
            if (lastDot > 0) {
              final prefix = ip.substring(0, lastDot);
              targets.add('$prefix.1');
              targets.add('$prefix.2');
            }
          }
        }
      }
    } catch (_) {}

    for (final host in targets) {
      if (_disposed) break;
      // Skip if already connected to this host
      final alreadyConnected = _links.values.any(
        (l) => l.address == host && !l.closed,
      );
      if (!alreadyConnected && !_connectingHosts.contains(host)) {
        unawaited(connectTo(host, port: defaultLanPort, isProbe: true));
      }
    }
  }

  Future<bool> connectTo(
    String host, {
    int port = defaultLanPort,
    String? expectedPeerId,
    String? expectedName,
    bool isProbe = false,
  }) async {
    if (_disposed || _connectingHosts.contains(host)) return false;

    // Check if already connected to this IP
    final existing = _links.values
        .where((l) => l.address == host && !l.closed)
        .firstOrNull;
    if (existing != null) return true;

    _connectingHosts.add(host);
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 1200),
      );
      _connectingHosts.remove(host);
      _setupSocket(socket, outbound: true, expectedPeerId: expectedPeerId);
      return true;
    } catch (_) {
      _connectingHosts.remove(host);
      if (!isProbe) {
        _events.add(
          LanLogEvent(
            'Could not connect to $host:$port',
            level: BleLogLevel.warning,
          ),
        );
      }
      return false;
    }
  }

  void _onIncomingSocket(Socket socket) {
    _setupSocket(socket, outbound: false);
  }

  void _setupSocket(
    Socket socket, {
    required bool outbound,
    String? expectedPeerId,
  }) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final linkId = 'lan:${socket.remoteAddress.address}:${socket.remotePort}';
    final address = socket.remoteAddress.address;

    final linkType = _detectLinkType(address);
    final link = _LanLink(
      socket: socket,
      linkId: linkId,
      address: address,
      linkType: linkType,
      outbound: outbound,
    );

    _links[linkId] = link;

    socket.listen(
      (data) => _onSocketData(link, data),
      onDone: () => _closeLink(linkId, 'connection closed by peer'),
      onError: (e) => _closeLink(linkId, 'socket error: $e'),
      cancelOnError: true,
    );

    // Send HELLO immediately
    _sendHello(link);
  }

  LanLinkType _detectLinkType(String address) {
    if (address == '127.0.0.1' ||
        address.startsWith('192.168.42.') ||
        address.startsWith('192.168.137.')) {
      return LanLinkType.usb;
    }
    return LanLinkType.wifi;
  }

  void _sendHello(_LanLink link) {
    final payload = utf8.encode('$selfId:$_selfName');
    final frame = Frame(
      type: FrameType.hello,
      packetId: Random().nextInt(0xFFFFFFFF),
      chunkIndex: 0,
      chunkCount: 1,
      payload: Uint8List.fromList(payload),
    );
    link.sendFrame(frame);
  }

  void _onSocketData(_LanLink link, Uint8List chunk) {
    link.rxBuffer.add(chunk);
    _processRx(link);
  }

  void _processRx(_LanLink link) {
    while (link.rxBuffer.length >= 4) {
      final bytes = link.rxBuffer.toBytes();
      final view = ByteData.sublistView(bytes);
      final frameLen = view.getUint32(0, Endian.big);

      if (frameLen > 64 * 1024) {
        _closeLink(link.linkId, 'frame size exceeded ($frameLen bytes)');
        return;
      }

      if (bytes.length < 4 + frameLen) {
        // Incomplete frame, wait for more chunks
        return;
      }

      final frameBytes = bytes.sublist(4, 4 + frameLen);
      // Consume from buffer
      final remaining = bytes.sublist(4 + frameLen);
      link.rxBuffer.clear();
      if (remaining.isNotEmpty) link.rxBuffer.add(remaining);

      final frame = Frame.tryDecode(Uint8List.fromList(frameBytes));
      if (frame != null) {
        _handleFrame(link, frame);
      }
    }
  }

  void _handleFrame(_LanLink link, Frame frame) {
    if (frame.type == FrameType.hello) {
      final text = utf8.decode(frame.payload, allowMalformed: true);
      final colon = text.indexOf(':');
      if (colon < 0) return;
      final peerId = text.substring(0, colon);
      final peerName = text.substring(colon + 1);

      if (peerId == selfId) {
        // Connected to self on loopback
        _closeLink(link.linkId, 'loopback self-connection');
        return;
      }

      link.peerId = peerId;
      link.peerName = peerName;
      link.ready = true;

      _events.add(
        LanPeerUpEvent(
          peerId: peerId,
          name: peerName,
          linkId: link.linkId,
          address: link.address,
          linkType: link.linkType,
        ),
      );
      _notifyState();
      return;
    }

    if (!link.ready || link.peerId == null) return;

    final assembled = _assembler.add(frame);
    if (assembled != null) {
      _events.add(
        LanDataEvent(
          linkId: link.linkId,
          peerId: link.peerId!,
          type: assembled.type,
          payload: assembled.payload,
        ),
      );
    }
  }

  void _closeLink(String linkId, String reason) {
    final link = _links.remove(linkId);
    if (link == null) return;
    link.closed = true;
    try {
      link.socket.destroy();
    } catch (_) {}

    if (link.peerId != null && link.ready) {
      _events.add(
        LanPeerDownEvent(
          peerId: link.peerId!,
          linkId: linkId,
          address: link.address,
        ),
      );
      _notifyState();
    }
  }

  int broadcast(FrameType type, Uint8List payload, {String? excludePeerId}) {
    var sentCount = 0;
    for (final link in _links.values) {
      if (!link.ready || link.closed) continue;
      if (excludePeerId != null && link.peerId == excludePeerId) continue;
      link.sendPayload(type, payload);
      sentCount++;
    }
    return sentCount;
  }

  bool sendToPeer(String peerId, FrameType type, Uint8List payload) {
    for (final link in _links.values) {
      if (link.ready && !link.closed && link.peerId == peerId) {
        link.sendPayload(type, payload);
        return true;
      }
    }
    return false;
  }

  bool sendOnLink(String linkId, FrameType type, Uint8List payload) {
    final link = _links[linkId];
    if (link != null && link.ready && !link.closed) {
      link.sendPayload(type, payload);
      return true;
    }
    return false;
  }

  void _notifyState() async {
    if (_disposed) return;
    final addresses = <String>[];
    var usbActive = false;
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        final name = iface.name.toLowerCase();
        final isUsb =
            name.contains('rndis') ||
            name.contains('usb') ||
            name.contains('ncm');
        for (final a in iface.addresses) {
          addresses.add(a.address);
          if (isUsb ||
              a.address.startsWith('192.168.42.') ||
              a.address.startsWith('192.168.137.')) {
            usbActive = true;
          }
        }
      }
    } catch (_) {}

    _events.add(
      LanStateEvent(
        active: _started,
        port: _actualPort,
        localAddresses: addresses,
        usbConnected: usbActive,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _started = false;

    _beaconTimer?.cancel();
    _usbProbeTimer?.cancel();

    for (final link in _links.values.toList()) {
      try {
        link.socket.destroy();
      } catch (_) {}
    }
    _links.clear();

    try {
      await _server?.close();
    } catch (_) {}
    try {
      _beaconRx?.close();
    } catch (_) {}
    try {
      _beaconTx?.close();
    } catch (_) {}

    await _events.close();
  }
}

class _LanLink {
  _LanLink({
    required this.socket,
    required this.linkId,
    required this.address,
    required this.linkType,
    required this.outbound,
  });

  final Socket socket;
  final String linkId;
  final String address;
  final LanLinkType linkType;
  final bool outbound;

  String? peerId;
  String? peerName;
  bool ready = false;
  bool closed = false;

  final BytesBuilder rxBuffer = BytesBuilder(copy: false);

  int get pendingBytes => 0;

  void sendFrame(Frame frame) {
    if (closed) return;
    final frameBytes = frame.encode();
    final header = ByteData(4)..setUint32(0, frameBytes.length, Endian.big);
    try {
      socket.add(header.buffer.asUint8List());
      socket.add(frameBytes);
    } catch (_) {
      closed = true;
    }
  }

  void sendPayload(FrameType type, Uint8List payload) {
    if (closed) return;
    final packetId = Random().nextInt(0xFFFFFFFF);
    final count =
        (payload.length + maxChunkPayloadBytes - 1) ~/ maxChunkPayloadBytes;
    final actualCount = count == 0 ? 1 : count;

    for (var i = 0; i < actualCount; i++) {
      final start = i * maxChunkPayloadBytes;
      final end = min(start + maxChunkPayloadBytes, payload.length);
      final chunk = payload.sublist(start, end);
      sendFrame(
        Frame(
          type: type,
          packetId: packetId,
          chunkIndex: i,
          chunkCount: actualCount,
          payload: Uint8List.fromList(chunk),
        ),
      );
    }
  }
}

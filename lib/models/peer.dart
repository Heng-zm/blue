import 'package:characters/characters.dart';

import '../core/ids.dart';

class Peer {
  Peer({
    required this.id,
    required this.name,
    this.connected = false,
    this.rssi = 0,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String id;
  String name;
  bool connected;
  int rssi;
  DateTime lastSeen;

  String get shortId => shortPeerId(id);

  String get initial {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
  }
}

/// A device seen advertising the MGS service.
class NearbyDevice {
  NearbyDevice({
    required this.address,
    required this.rssi,
    this.peerId,
    this.name,
    this.connected = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String address;
  final int rssi;
  String? peerId;
  String? name;
  bool connected;
  DateTime lastSeen;

  bool get identified => peerId != null;

  String get displayName {
    final known = name?.trim();
    if (known != null && known.isNotEmpty) return known;
    if (peerId != null) {
      return 'MGS ${shortPeerId(peerId!)}';
    }
    return 'Nearby device';
  }
}

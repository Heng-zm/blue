import 'dart:math';
import 'dart:typed_data';

/// Binary framing used on top of a BLE characteristic.
///
/// Each GATT write / notification carries exactly one frame. A logical
/// payload is split into [chunkCount] frames that share a [packetId] and are
/// reassembled on the other side.
///
/// Layout (big endian):
///
///   0      version (1 byte)
///   1      frame type (1 byte)
///   2..5   packet id (uint32)
///   6      chunk index (uint8)
///   7      chunk count (uint8)
///   8..    chunk payload
const int frameVersion = 1;
const int frameHeaderLength = 8;
const int maxFrameChunkCount = 255;
const int maxChunkPayloadBytes = 240;
const int maxFramePayloadBytes = 24 * 1024;
const int maxAssemblies = 16;
const Duration frameAssemblyTimeout = Duration(seconds: 25);

enum FrameType {
  hello(1),
  message(2),
  ack(3),
  ping(4);

  const FrameType(this.code);

  final int code;

  static FrameType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

class Frame {
  const Frame({
    required this.type,
    required this.packetId,
    required this.chunkIndex,
    required this.chunkCount,
    required this.payload,
  });

  final FrameType type;

  /// Random id shared by all chunks of one logical payload.
  final int packetId;
  final int chunkIndex;
  final int chunkCount;
  final Uint8List payload;

  Uint8List encode() {
    final bytes = Uint8List(frameHeaderLength + payload.length);
    final view = ByteData.sublistView(bytes);
    bytes[0] = frameVersion;
    bytes[1] = type.code;
    view.setUint32(2, packetId, Endian.big);
    bytes[6] = chunkIndex;
    bytes[7] = chunkCount;
    bytes.setRange(frameHeaderLength, bytes.length, payload);
    return bytes;
  }

  /// Returns `null` instead of throwing for anything that is not a valid frame.
  static Frame? tryDecode(Uint8List bytes) {
    if (bytes.length < frameHeaderLength) return null;
    if (bytes[0] != frameVersion) return null;
    final type = FrameType.fromCode(bytes[1]);
    if (type == null) return null;

    final view = ByteData.sublistView(bytes);
    final packetId = view.getUint32(2, Endian.big);
    final chunkIndex = bytes[6];
    final chunkCount = bytes[7];
    final payloadLength = bytes.length - frameHeaderLength;

    if (chunkCount == 0 || chunkCount > maxFrameChunkCount) return null;
    if (chunkIndex >= chunkCount) return null;
    if (payloadLength > maxChunkPayloadBytes) return null;

    return Frame(
      type: type,
      packetId: packetId,
      chunkIndex: chunkIndex,
      chunkCount: chunkCount,
      payload: Uint8List.fromList(bytes.sublist(frameHeaderLength)),
    );
  }
}

int randomPacketId([Random? random]) =>
    (random ?? Random.secure()).nextInt(0x100000000);

/// Splits [payload] into frames that each fit into [maxChunkSize] bytes.
///
/// Throws [ArgumentError] when the payload cannot be represented with the
/// protocol limits. Callers should surface that to the user instead of
/// silently truncating.
List<Frame> buildFrames({
  required FrameType type,
  required Uint8List payload,
  required int maxChunkSize,
  Random? random,
}) {
  if (payload.length > maxFramePayloadBytes) {
    throw ArgumentError('Payload is too large (${payload.length} bytes).');
  }

  final chunkSize = maxChunkSize < 1
      ? 1
      : (maxChunkSize > maxChunkPayloadBytes
            ? maxChunkPayloadBytes
            : maxChunkSize);
  final chunkCount = max(1, (payload.length + chunkSize - 1) ~/ chunkSize);
  if (chunkCount > maxFrameChunkCount) {
    throw ArgumentError(
      'Payload needs $chunkCount frames, but the limit is '
      '$maxFrameChunkCount. Negotiate a larger MTU or shorten the message.',
    );
  }

  final packetId = randomPacketId(random);
  final frames = <Frame>[];
  for (var index = 0; index < chunkCount; index++) {
    final start = index * chunkSize;
    final end = min(start + chunkSize, payload.length);
    frames.add(
      Frame(
        type: type,
        packetId: packetId,
        chunkIndex: index,
        chunkCount: chunkCount,
        payload: Uint8List.sublistView(payload, start, end),
      ),
    );
  }
  return frames;
}

class FrameAssembler {
  final Map<int, _Assembly> _assemblies = {};

  int get activeAssemblies => _assemblies.length;

  /// Feeds one frame. Returns a completed, single-chunk frame when the last
  /// missing chunk arrived, otherwise `null`.
  Frame? add(Frame frame, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    _evictExpired(clock);

    var assembly = _assemblies[frame.packetId];
    if (assembly != null &&
        (assembly.type != frame.type ||
            assembly.chunkCount != frame.chunkCount)) {
      _assemblies.remove(frame.packetId);
      assembly = null;
    }

    if (assembly == null) {
      if (_assemblies.length >= maxAssemblies) {
        _evictOldest();
      }
      assembly = _Assembly(
        type: frame.type,
        chunkCount: frame.chunkCount,
        createdAt: clock,
      );
      _assemblies[frame.packetId] = assembly;
    }

    if (assembly.chunks.containsKey(frame.chunkIndex)) {
      // Duplicate chunk: ignore instead of corrupting the buffer.
      return null;
    }
    assembly.chunks[frame.chunkIndex] = frame.payload;
    assembly.byteLength += frame.payload.length;

    if (assembly.byteLength > maxFramePayloadBytes) {
      _assemblies.remove(frame.packetId);
      return null;
    }
    if (assembly.chunks.length < assembly.chunkCount) return null;

    final output = Uint8List(assembly.byteLength);
    var offset = 0;
    for (var index = 0; index < assembly.chunkCount; index++) {
      final chunk = assembly.chunks[index];
      if (chunk == null) {
        _assemblies.remove(frame.packetId);
        return null;
      }
      output.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

    _assemblies.remove(frame.packetId);
    return Frame(
      type: assembly.type,
      packetId: frame.packetId,
      chunkIndex: 0,
      chunkCount: 1,
      payload: output,
    );
  }

  void clear() => _assemblies.clear();

  void _evictExpired(DateTime now) {
    final cutoff = now.subtract(frameAssemblyTimeout);
    _assemblies.removeWhere(
      (_, assembly) => assembly.createdAt.isBefore(cutoff),
    );
  }

  void _evictOldest() {
    int? oldestKey;
    DateTime? oldestAt;
    for (final entry in _assemblies.entries) {
      if (oldestAt == null || entry.value.createdAt.isBefore(oldestAt)) {
        oldestAt = entry.value.createdAt;
        oldestKey = entry.key;
      }
    }
    if (oldestKey != null) _assemblies.remove(oldestKey);
  }
}

class _Assembly {
  _Assembly({
    required this.type,
    required this.chunkCount,
    required this.createdAt,
  });

  final FrameType type;
  final int chunkCount;
  final DateTime createdAt;
  final Map<int, Uint8List> chunks = {};
  int byteLength = 0;
}

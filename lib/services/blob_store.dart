import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-disk storage for file and voice payloads.
///
/// Blobs live next to the state file in a `blobs/` directory. Only the
/// attachment descriptor is kept in `mgs_state.json`.
class BlobStore {
  BlobStore({this.directoryName = 'blobs'});

  final String directoryName;
  Directory? _cached;

  Future<Directory> _directory() async {
    final cached = _cached;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, directoryName));
    await directory.create(recursive: true);
    _cached = directory;
    return directory;
  }

  Future<String> saveBytes({
    required String blobId,
    required String name,
    required Uint8List bytes,
  }) async {
    final file = await _fileFor(blobId, name);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<File> _fileFor(String blobId, String name) async {
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(blobId)) {
      throw ArgumentError('Invalid blob id.');
    }
    final directory = await _directory();
    var extension = p.extension(name).toLowerCase();
    if (!RegExp(r'^\.[a-z0-9]{1,12}$').hasMatch(extension)) {
      extension = '.bin';
    }
    return File(p.join(directory.path, '$blobId$extension'));
  }

  Future<String?> find(String blobId, String name) async {
    final file = await _fileFor(blobId, name);
    return await file.exists() ? file.path : null;
  }

  Future<Uint8List?> read(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> deletePath(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort; a locked file is cleaned up on the next clear.
    }
  }

  Future<void> clear() async {
    try {
      final directory = await _directory();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // Best effort.
    }
    _cached = null;
  }
}

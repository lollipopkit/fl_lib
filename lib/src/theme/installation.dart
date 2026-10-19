import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/rust/api/theme.dart';

final installationIdPattern = RegExp(r'^[a-f0-9]{64}$');

/// Writes [prepared]'s files into `<rootPath>/<installation id>`, staged and
/// moved in whole so a failed write leaves nothing half installed, and one
/// already there (unreadable, or it would not be replaced) as it was.
Future<void> writeInstallation(String rootPath, PreparedTheme prepared) async {
  final directory = Directory(rootPath.joinPath(prepared.installationId));
  await Directory(rootPath).create(recursive: true);
  // Not a digest, so nothing that lists installations reads these.
  final staging = await Directory(rootPath).createTemp('.installing-');
  Directory? previous;
  try {
    for (final file in prepared.files) {
      final target = File(staging.path.joinPath(file.path));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.bytes, flush: true);
    }
    if (await directory.exists()) {
      previous = await directory.rename('${staging.path}.previous');
    }
    await staging.rename(directory.path);
  } catch (_) {
    if (previous != null && !await directory.exists()) {
      await previous.rename(directory.path);
      previous = null;
    }
    rethrow;
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
    if (previous != null && await previous.exists()) {
      await previous.delete(recursive: true);
    }
  }
}

/// The manifest an installation wrote, or null when there is none to read.
String? installedManifest(String directory, {required int maxBytes}) {
  final file = File(directory.joinPath('manifest.toml'));
  if (!file.existsSync() || file.lengthSync() > maxBytes) return null;
  return file.readAsStringSync();
}

/// The file names an installation's `icons/` holds.
List<String> installedIconFiles(String directory) {
  final iconDir = Directory(directory.joinPath('icons'));
  if (!iconDir.existsSync()) return const [];
  return [
    for (final entry in iconDir.listSync(followLinks: false))
      if (entry is File) entry.uri.pathSegments.last,
  ];
}

/// Every installation directory under [rootPath], by installation id.
Iterable<String> installationIds(String rootPath) sync* {
  final directory = Directory(rootPath);
  if (!directory.existsSync()) return;
  for (final entry in directory.listSync(followLinks: false)) {
    if (entry is! Directory) continue;
    final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
    // Staging directories are not digests; an installation is renamed to its
    // digest only once complete.
    if (installationIdPattern.hasMatch(name)) yield name;
  }
}

/// Where the `.fsbt` an installation came from is kept: what is installed
/// is rewritten from it, and cannot be packed back into the same bytes, so
/// a backup has nothing else to carry a package the store does not hold
/// (#1637). Beside the installations, under a name nothing reads as one.
String _sourcePath(String rootPath, String installationId) =>
    rootPath.joinPath('.sources').joinPath('$installationId.fsbt');

Future<void> keepSource(
  String rootPath,
  String installationId,
  List<int> bytes,
) async {
  try {
    final file = File(_sourcePath(rootPath, installationId));
    // One that is there already stays only when it is whole: a write cut
    // short would otherwise be kept, and fail [readSource]'s check for good.
    if (await _sourceIntact(file, installationId)) return;
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
  } catch (error, stack) {
    // The package is installed either way; only a backup of it is lost.
    Loggers.app.warning('Keeping theme source $installationId', error, stack);
  }
}

Future<void> dropSource(String rootPath, String installationId) async {
  final file = File(_sourcePath(rootPath, installationId));
  if (await file.exists()) await file.delete();
}

/// The `.fsbt` [installationId] was installed from, or null for one
/// installed from a folder, or before these were kept. Checked against the
/// id, which is its digest: a file changed on disk is no source of it.
Future<Uint8List?> readSource(String rootPath, String installationId) async {
  if (!installationIdPattern.hasMatch(installationId)) return null;
  final file = File(_sourcePath(rootPath, installationId));
  try {
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != installationId) return null;
    return bytes;
  } on FileSystemException catch (error) {
    // As a missing one: the package is left out of a backup, not the backup.
    Loggers.app.warning('Reading theme source $installationId', error);
    return null;
  }
}

Future<bool> _sourceIntact(File file, String installationId) async {
  if (!await file.exists()) return false;
  try {
    return sha256.convert(await file.readAsBytes()).toString() ==
        installationId;
  } on FileSystemException {
    return false;
  }
}

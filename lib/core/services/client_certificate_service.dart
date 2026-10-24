import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pkcs12_parser/pkcs12_parser.dart';
import 'package:uuid/uuid.dart';

import '../models/client_certificate.dart';

/// A certificate import failure with a message that is safe to show to the
/// user. Parser internals stay out of the UI; the actionable distinction is
/// "wrong password" versus "this file cannot be read".
class ClientCertificateImportException implements Exception {
  final String message;

  const ClientCertificateImportException(this.message);

  @override
  String toString() => message;
}

/// Owns newly materialized files until an editor/import and its saves settle.
///
/// Only directory paths are shared across service instances. Registration occurs
/// before filesystem creation/rename, so a collector cannot observe an unleased
/// half-written identity. Closing joins admitted work before releasing paths.
class ClientCertificateFileLease {
  static final _zoneKey = Object();
  static final _references = <String, int>{};

  final _directories = <String>{};
  int _operations = 0;
  bool _closed = false;
  Completer<void>? _closing;

  Future<T> run<T>(Future<T> Function() action) async {
    if (_closed) throw StateError('Certificate file owner is closed.');
    _operations++;
    try {
      return await runZoned(action, zoneValues: {_zoneKey: this});
    } finally {
      _operations--;
      _releaseIfClosed();
    }
  }

  /// Completes after close and all admitted work have released their paths.
  Future<void> get whenClosed => _closed && _operations == 0
      ? Future<void>.value()
      : (_closing ??= Completer<void>()).future;

  /// Idempotent; disposal cannot release files beneath an admitted save/import.
  Future<void> close() {
    _closed = true;
    _releaseIfClosed();
    if (_operations == 0) return Future<void>.value();
    return (_closing ??= Completer<void>()).future;
  }

  void _retain(String directory) {
    if (_closed && _operations == 0) {
      throw StateError('Certificate file owner is closed.');
    }
    final path = ClientCertificateService._normalize(directory);
    if (_directories.add(path)) {
      _references[path] = (_references[path] ?? 0) + 1;
    }
  }

  /// Drops a replaced pick without retaining every abandoned path for the
  /// lifetime of a long-lived editor. This does not delete any files.
  void releaseIdentity(ClientCertificateConfig config) =>
      _releaseDirectory(config.directoryPath);

  void _releaseDirectory(String directory) {
    final path = ClientCertificateService._normalize(directory);
    if (_directories.remove(path)) {
      final remaining = _references[path]! - 1;
      if (remaining == 0) {
        _references.remove(path);
      } else {
        _references[path] = remaining;
      }
    }
  }

  void _releaseIfClosed() {
    if (!_closed || _operations != 0) return;
    for (final path in _directories.toList()) {
      _releaseDirectory(path);
    }
    final closing = _closing;
    _closing = null;
    closing?.complete();
  }

  static ClientCertificateFileLease? get _current =>
      Zone.current[_zoneKey] as ClientCertificateFileLease?;

  static void _retainMaterializedDirectory(String path) =>
      _current?._retain(path);

  static bool _isLeased(String path) =>
      _references.containsKey(ClientCertificateService._normalize(path));
}

/// Removes certificate/key files that no saved connection references.
///
/// Kept as a narrow interface so [ConnectionManager] can garbage-collect
/// identities after a successful save without depending on `path_provider` in
/// unit tests.
abstract interface class ClientCertificateFileStore {
  /// Deletes every stored identity whose directory is not in
  /// [referencedDirectoryPaths] and no live file lease owns. Best-effort:
  /// abandoned staged imports are also cleared.
  Future<void> deleteUnreferenced(Iterable<String> referencedDirectoryPaths);
}

/// Imports PKCS#12 or PEM client certificates into app-private storage.
///
/// The certificate and key are written as separate PEM files because
/// `SecurityContext` loads them separately. Keys never leave the app sandbox.
///
/// Imports are **staged**: files are written under `client-certs/.staging/`
/// and only moved into their permanent `client-certs/<id>/` directory by
/// [commit], after connection validation. Editors/imports use a
/// [ClientCertificateFileLease] through save, rollback and native cleanup.
/// A failed save is not proof of rollback: collect permanent files only under
/// the saved-list owner after reading their physical references.
class ClientCertificateService implements ClientCertificateFileStore {
  static const String _directoryName = 'client-certs';
  static const String _stagingDirectoryName = '.staging';
  static const String _certificateFileName = 'certificate.pem';
  static const String _privateKeyFileName = 'private-key.pem';

  final Future<Directory> Function() _supportDirectory;

  ClientCertificateService({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  /// Extracts the leaf certificate, chain, and private key from a `.p12`/
  /// `.pfx` container.
  ///
  /// The container password is used only to decrypt the file. The extracted
  /// key is written unencrypted, so the password is deliberately **not**
  /// retained: storing it would add a secret with no remaining use.
  Future<ClientCertificateConfig> importPkcs12({
    required List<int> bytes,
    required String? password,
    required String label,
  }) async {
    final Pkcs12 parsed;
    try {
      parsed = Pkcs12.load(
        Uint8List.fromList(bytes),
        password == null || password.isEmpty ? null : password,
      );
    } on Pkcs12MacMismatchException {
      throw const ClientCertificateImportException(
        'The certificate password is incorrect, or the file is corrupted.',
      );
    } on Pkcs12BadPasswordException {
      throw const ClientCertificateImportException(
        'The certificate password is incorrect.',
      );
    } on Pkcs12UnsupportedException {
      throw const ClientCertificateImportException(
        'This certificate uses an encryption method the app cannot read.',
      );
    } on Pkcs12ParseException {
      throw const ClientCertificateImportException(
        'The selected file is not a readable PKCS#12 (.p12/.pfx) certificate.',
      );
    } on Pkcs12Exception {
      throw const ClientCertificateImportException(
        'The selected certificate could not be read.',
      );
    }

    // SecurityContext.useCertificateChain expects one PEM chain file, leaf
    // first, so concatenate the parser's issuer-ordered CA certificates.
    final certificatePem = [parsed.certificatePem, ...parsed.caChainPem].join();
    return _writePair(
      certificatePem: certificatePem,
      privateKeyPem: parsed.privateKeyPem,
      // Pkcs12.load returns an unencrypted key, so no password is needed.
      password: null,
      label: _resolveLabel(label, parsed.certificatePem),
    );
  }

  /// Stores an already-PEM certificate/key pair chosen by the user.
  Future<ClientCertificateConfig> importPemPair({
    required List<int> certificateBytes,
    required List<int> privateKeyBytes,
    String? password,
    required String label,
  }) async {
    final certificatePem = _asPemText(certificateBytes);
    final privateKeyPem = _asPemText(privateKeyBytes);
    if (!certificatePem.contains('-----BEGIN CERTIFICATE-----')) {
      throw const ClientCertificateImportException(
        'The selected certificate is not a PEM certificate.',
      );
    }
    if (!privateKeyPem.contains('-----BEGIN') ||
        !privateKeyPem.contains('PRIVATE KEY-----')) {
      throw const ClientCertificateImportException(
        'The selected private key is not a PEM private key.',
      );
    }
    return _writePair(
      certificatePem: certificatePem,
      privateKeyPem: privateKeyPem,
      // Only an encrypted PEM key needs (and therefore retains) a password.
      password: _isEncryptedPrivateKey(privateKeyPem) ? password : null,
      label: _resolveLabel(label, certificatePem),
    );
  }

  /// Restores a key pair carried by an encrypted configuration backup.
  ///
  /// Run within a [ClientCertificateFileLease] until the account transaction
  /// settles: permanent files are not yet referenced while the import queues.
  Future<ClientCertificateConfig> restore({
    required String certificatePem,
    required String privateKeyPem,
    required String label,
    String? password,
  }) async {
    return _writePair(
      certificatePem: certificatePem,
      privateKeyPem: privateKeyPem,
      password: _isEncryptedPrivateKey(privateKeyPem) ? password : null,
      label: label,
      staged: false,
    );
  }

  /// Reads the PEM contents referenced by [config].
  ///
  /// Used by the encrypted backup export. Throws [ClientCertificateImportException]
  /// when a referenced file is missing so a backup never silently drops mTLS.
  Future<({String certificatePem, String privateKeyPem})> readPair(
    ClientCertificateConfig config,
  ) async {
    try {
      final certificatePem = await File(
        config.certificatePemPath,
      ).readAsString();
      final privateKeyPem = await File(config.privateKeyPemPath).readAsString();
      return (certificatePem: certificatePem, privateKeyPem: privateKeyPem);
    } catch (_) {
      throw const ClientCertificateImportException(
        'The saved client certificate files could not be read.',
      );
    }
  }

  /// Moves a staged import into permanent storage.
  ///
  /// Returns [config] unchanged when it is already permanent.
  Future<ClientCertificateConfig> commit(ClientCertificateConfig config) async {
    if (!await isStaged(config)) {
      ClientCertificateFileLease._retainMaterializedDirectory(
        config.directoryPath,
      );
      return config;
    }
    final directory = Directory(config.directoryPath);
    final root = await _rootDirectory();
    final destination = Directory(
      '${root.path}${Platform.pathSeparator}${const Uuid().v4()}',
    );
    ClientCertificateFileLease._retainMaterializedDirectory(destination.path);
    try {
      await destination.parent.create(recursive: true);
      await directory.rename(destination.path);
      ClientCertificateFileLease._current?._releaseDirectory(directory.path);
    } catch (_) {
      throw const ClientCertificateImportException(
        'The client certificate could not be stored securely on this device.',
      );
    }
    return ClientCertificateConfig(
      label: config.label,
      certificatePemPath:
          '${destination.path}${Platform.pathSeparator}$_certificateFileName',
      privateKeyPemPath:
          '${destination.path}${Platform.pathSeparator}$_privateKeyFileName',
      privateKeyPassword: config.privateKeyPassword,
    );
  }

  /// Whether [config] still points into the staging area.
  Future<bool> isStaged(ClientCertificateConfig config) async {
    final staging = await _stagingRoot();
    return _isWithin(config.directoryPath, staging.path);
  }

  /// Deletes a staged import that was never committed.
  ///
  /// Permanent identities are left alone: they may still be referenced by the
  /// saved connection.
  Future<void> discard(ClientCertificateConfig config) async {
    if (!await isStaged(config)) return;
    await _deleteDirectory(config.directoryPath);
  }

  /// Deletes a permanent identity. Only call once nothing references it.
  Future<void> delete(ClientCertificateConfig config) async {
    final root = await _rootDirectory();
    if (!_isWithin(config.directoryPath, root.path)) return;
    if (await isStaged(config)) return;
    await _deleteDirectory(config.directoryPath, unlessLeased: true);
  }

  /// Removes abandoned staged imports (app start, or after a failed save).
  Future<void> cleanupStaging() async {
    try {
      final staging = await _stagingRoot();
      if (!staging.existsSync()) return;
      await for (final entity in staging.list()) {
        if (entity is Directory) {
          await _deleteDirectory(entity.path, unlessLeased: true);
        }
      }
    } catch (_) {
      // Cleanup is best-effort; an unreadable staging directory must not stop
      // the app from starting.
    }
  }

  @override
  Future<void> deleteUnreferenced(
    Iterable<String> referencedDirectoryPaths,
  ) async {
    final root = await _rootDirectory();
    if (!root.existsSync()) return;
    final referenced = <String>{
      for (final path in referencedDirectoryPaths) _normalize(path),
    };
    // Staging is not saved metadata; a live editor still owns its staged files.
    await cleanupStaging();
    final stagingPath = (await _stagingRoot()).path;
    try {
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        if (_isWithin(entity.path, stagingPath)) continue;
        if (referenced.contains(_normalize(entity.path))) continue;
        await _deleteDirectory(entity.path, unlessLeased: true);
      }
    } catch (_) {
      // Garbage collection must never fail a connection save.
    }
  }

  Future<ClientCertificateConfig> _writePair({
    required String certificatePem,
    required String privateKeyPem,
    required String? password,
    required String label,
    bool staged = true,
  }) async {
    final directory = staged
        ? await _newStagingDirectory()
        : await _newPermanentDirectory();
    final certificateFile = File(
      '${directory.path}${Platform.pathSeparator}$_certificateFileName',
    );
    final privateKeyFile = File(
      '${directory.path}${Platform.pathSeparator}$_privateKeyFileName',
    );
    try {
      await certificateFile.writeAsString(certificatePem, flush: true);
      await privateKeyFile.writeAsString(privateKeyPem, flush: true);
    } catch (_) {
      // A partial import is unusable; remove it rather than leaving a config
      // that points at half-written PEM files.
      await _deleteDirectory(directory.path);
      throw const ClientCertificateImportException(
        'The certificate could not be stored securely on this device.',
      );
    }

    final keyPassword = password == null || password.isEmpty ? null : password;
    return ClientCertificateConfig(
      label: label,
      certificatePemPath: certificateFile.path,
      privateKeyPemPath: privateKeyFile.path,
      privateKeyPassword: keyPassword,
    );
  }

  Future<Directory> _rootDirectory() async {
    final support = await _supportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}$_directoryName');
  }

  Future<Directory> _stagingRoot() async {
    final root = await _rootDirectory();
    return Directory(
      '${root.path}${Platform.pathSeparator}$_stagingDirectoryName',
    );
  }

  Future<Directory> _newStagingDirectory() async {
    final staging = await _stagingRoot();
    final directory = Directory(
      '${staging.path}${Platform.pathSeparator}${const Uuid().v4()}',
    );
    ClientCertificateFileLease._retainMaterializedDirectory(directory.path);
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _newPermanentDirectory() async {
    final root = await _rootDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}${const Uuid().v4()}',
    );
    ClientCertificateFileLease._retainMaterializedDirectory(directory.path);
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _deleteDirectory(
    String path, {
    bool unlessLeased = false,
  }) async {
    try {
      if (unlessLeased && ClientCertificateFileLease._isLeased(path)) return;
      final directory = Directory(path);
      if (directory.existsSync()) await directory.delete(recursive: true);
    } catch (_) {
      // A leftover directory is harmless; the original failure is actionable.
    }
  }

  static bool _isWithin(String candidate, String parent) {
    final normalizedCandidate = _normalize(candidate);
    final normalizedParent = _normalize(parent);
    return normalizedCandidate == normalizedParent ||
        normalizedCandidate.startsWith(
          '$normalizedParent${Platform.pathSeparator}',
        );
  }

  static String _normalize(String path) {
    var value = path;
    while (value.length > 1 && value.endsWith(Platform.pathSeparator)) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static bool _isEncryptedPrivateKey(String privateKeyPem) =>
      privateKeyPem.contains('ENCRYPTED PRIVATE KEY');

  /// Uses the caller-supplied label (usually the file name), falling back to
  /// the certificate CN when that label is blank.
  static String _resolveLabel(String label, String certificatePem) {
    final trimmed = label.trim();
    if (trimmed.isNotEmpty) return trimmed;
    try {
      final certificate = X509CertificateDer(decodePem(certificatePem));
      final commonName = certificate.subject['CN']?.trim();
      if (commonName != null && commonName.isNotEmpty) return commonName;
    } catch (_) {
      // A readable label is cosmetic; the import itself has already succeeded.
    }
    return 'Client certificate';
  }

  static String _asPemText(List<int> bytes) {
    return String.fromCharCodes(bytes);
  }
}

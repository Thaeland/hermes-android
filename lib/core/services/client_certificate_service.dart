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

/// Imports PKCS#12 or PEM client certificates into app-private storage.
///
/// The certificate and key are written as separate PEM files because
/// `SecurityContext` loads them separately. Keys never leave the app sandbox.
class ClientCertificateService {
  static const String _directoryName = 'client-certs';
  static const String _certificateFileName = 'certificate.pem';
  static const String _privateKeyFileName = 'private-key.pem';

  final Future<Directory> Function() _supportDirectory;

  ClientCertificateService({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  /// Extracts the leaf certificate, chain, and private key from a `.p12`/
  /// `.pfx` container.
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
      password: password,
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
      password: password,
      label: _resolveLabel(label, certificatePem),
    );
  }

  Future<ClientCertificateConfig> _writePair({
    required String certificatePem,
    required String privateKeyPem,
    required String? password,
    required String label,
  }) async {
    final directory = await _newCertificateDirectory();
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
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // The original storage failure is the actionable one.
      }
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

  Future<Directory> _newCertificateDirectory() async {
    final support = await _supportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}$_directoryName'
      '${Platform.pathSeparator}${const Uuid().v4()}',
    );
    await directory.create(recursive: true);
    return directory;
  }

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

// ignore_for_file: prefer_initializing_formals

import 'package:shared_preferences/shared_preferences.dart';

import '../models/client_certificate.dart';
import 'app_update_service.dart';
import 'chat_density_preference.dart';
import 'client_certificate_service.dart';
import 'config_backup.dart';
import 'connection_manager.dart';
import 'local_chat_pin_store.dart';

/// How an imported backup is applied to the connections already on the device.
enum ConfigImportMode {
  /// Connections present in the backup are added or updated by id; anything
  /// else already on the device is kept.
  merge,

  /// The device ends up with exactly the connections in the backup.
  replace,
}

class ConfigImportResult {
  final int connectionsAdded;
  final int connectionsUpdated;
  final int connectionsRemoved;
  final int preferencesApplied;
  final int preferencesSkipped;

  const ConfigImportResult({
    required this.connectionsAdded,
    required this.connectionsUpdated,
    required this.connectionsRemoved,
    required this.preferencesApplied,
    required this.preferencesSkipped,
  });

  String get summary {
    final parts = <String>[];
    if (connectionsAdded > 0) parts.add('$connectionsAdded added');
    if (connectionsUpdated > 0) parts.add('$connectionsUpdated updated');
    if (connectionsRemoved > 0) parts.add('$connectionsRemoved removed');
    final connections = parts.isEmpty
        ? 'No connection changes'
        : 'Connections: ${parts.join(', ')}';
    return '$connections · $preferencesApplied settings restored';
  }
}

/// Builds and applies configuration backups.
///
/// Only keys this app actually owns are exported and imported. Everything else
/// in `SharedPreferences` — plugin caches, the turn journal, the raw connection
/// list, transient UI state — is deliberately excluded, so an imported file can
/// never overwrite storage the backup format does not understand.
class ConfigBackupService {
  /// Exact preference keys that are safe to carry between devices.
  static const Set<String> exactPreferenceKeys = <String>{
    'theme_mode',
    'verbose_mode',
    'voice_name',
    'voice_locale',
    'app_text_size_preference',
    'chat_density',
    AppUpdateService.checkOnLaunchKey,
    AppUpdateService.skippedVersionKey,
  };

  /// Prefixes for per-connection and per-chat preferences, which are keyed by
  /// ids that the backup restores alongside them.
  static const List<String> preferenceKeyPrefixes = <String>[
    'session_search.',
    'chat_model_override.',
    'excluded_session_sources_',
    'chat_spaces_v1_',
    LocalChatPinStore.keyPrefix,
  ];

  final ConnectionManager _connectionManager;
  final SharedPreferences _preferences;
  final ClientCertificateService _certificates;

  ConfigBackupService({
    required ConnectionManager connectionManager,
    required SharedPreferences preferences,
    ClientCertificateService? certificates,
  }) : _connectionManager = connectionManager,
       _preferences = preferences,
       _certificates = certificates ?? ClientCertificateService();

  static bool isBackedUpKey(String key) {
    if (exactPreferenceKeys.contains(key)) return true;
    return preferenceKeyPrefixes.any(key.startsWith);
  }

  Future<ConfigBackup> export({required String appVersion}) async {
    final connections = await _connectionManager.loadConnectionsWithSecrets();

    final certificates = <String, ClientCertificateBackup>{};
    for (final connection in connections) {
      final certificate = connection.clientCertificate;
      if (certificate == null) continue;
      try {
        final pair = await _certificates.readPair(certificate);
        certificates[connection.id] = ClientCertificateBackup(
          label: certificate.label,
          certificatePem: pair.certificatePem,
          privateKeyPem: pair.privateKeyPem,
          password: certificate.privateKeyPassword,
        );
      } on ClientCertificateImportException catch (error) {
        // Never emit a backup that claims a complete restore while dropping an
        // mTLS identity: the user would only discover the loss on the new
        // device, with no way to authenticate.
        throw ConfigBackupException(
          'The client certificate for "${connection.label}" could not be '
          'included in this backup: ${error.message}',
        );
      }
    }

    final preferences = <String, Object>{};
    for (final key in _preferences.getKeys()) {
      if (!isBackedUpKey(key)) continue;
      final value = _preferences.get(key);
      if (value == null) continue;
      if (value is bool || value is int || value is double || value is String) {
        preferences[key] = value;
      } else if (value is List<String>) {
        preferences[key] = List<String>.of(value);
      } else if (value is List) {
        preferences[key] = value.map((item) => item.toString()).toList();
      }
    }

    return ConfigBackup(
      createdAt: DateTime.now().toUtc(),
      appVersion: appVersion,
      connections: connections,
      clientCertificates: certificates,
      preferences: preferences,
    );
  }

  Future<ConfigImportResult> import(
    ConfigBackup backup, {
    required ConfigImportMode mode,
  }) async {
    final existingIds = _connectionManager
        .getConnections()
        .map((connection) => connection.id)
        .toSet();

    var added = 0;
    var updated = 0;
    for (final connection in backup.connections) {
      if (existingIds.contains(connection.id)) {
        updated++;
      } else {
        added++;
      }
    }
    final removed = mode == ConfigImportMode.replace
        ? existingIds
              .difference(
                backup.connections.map((connection) => connection.id).toSet(),
              )
              .length
        : 0;

    // Re-materialise every bundled identity into app-private storage before the
    // connections are committed, so an imported mTLS profile works immediately
    // and a failure cannot leave a connection pointing at missing files.
    final restoredConnections = <SavedConnection>[];
    final createdCertificates = <ClientCertificateConfig>[];
    try {
      for (final connection in backup.connections) {
        final certificate = backup.clientCertificates[connection.id];
        if (certificate == null) {
          restoredConnections.add(connection);
          continue;
        }
        final restored = await _certificates.restore(
          certificatePem: certificate.certificatePem,
          privateKeyPem: certificate.privateKeyPem,
          label: certificate.label,
          password: certificate.password,
        );
        createdCertificates.add(restored);
        restoredConnections.add(
          connection.copyWith(clientCertificate: restored),
        );
      }

      await _connectionManager.importConnections(
        restoredConnections,
        replaceExisting: mode == ConfigImportMode.replace,
      );
    } on ClientCertificateImportException catch (error) {
      await _deleteCertificates(createdCertificates);
      throw ConfigBackupException(error.message);
    } on CredentialStorageException catch (error) {
      await _deleteCertificates(createdCertificates);
      throw ConfigBackupException(error.message);
    } catch (_) {
      await _deleteCertificates(createdCertificates);
      rethrow;
    }

    var applied = 0;
    var skipped = 0;
    for (final entry in backup.preferences.entries) {
      if (!isBackedUpKey(entry.key)) {
        skipped++;
        continue;
      }
      final value = entry.value;
      if (value is bool) {
        await _preferences.setBool(entry.key, value);
      } else if (value is int) {
        await _preferences.setInt(entry.key, value);
      } else if (value is double) {
        await _preferences.setDouble(entry.key, value);
      } else if (value is String) {
        await _preferences.setString(entry.key, value);
      } else if (value is List<String>) {
        await _preferences.setStringList(entry.key, value);
      } else {
        skipped++;
        continue;
      }
      applied++;
    }

    // Preferences that are also held in memory must be re-read, not just
    // written: the settings card and any open chat took their copy at build
    // time and would otherwise keep showing the pre-import value.
    ChatDensityStore(_preferences).read();

    return ConfigImportResult(
      connectionsAdded: added,
      connectionsUpdated: updated,
      connectionsRemoved: removed,
      preferencesApplied: applied,
      preferencesSkipped: skipped,
    );
  }

  /// Best-effort removal of identities materialised by a failed import.
  Future<void> _deleteCertificates(
    List<ClientCertificateConfig> certificates,
  ) async {
    if (certificates.isEmpty) return;
    final Set<String> referenced;
    try {
      // A metadata write can commit physically before its ACK is lost, and a
      // persistent storage outage can also prevent rollback. Refresh the real
      // list: the preference cache may already contain the attempted rollback.
      await _preferences.reload();
      referenced = {
        for (final connection in _connectionManager.getConnections())
          if (connection.clientCertificate case final certificate?)
            certificate.directoryPath,
      };
    } catch (_) {
      // Unknown reachability is not proof that a key is unreferenced. Keep it
      // until a later successful connection commit can safely collect it.
      return;
    }
    for (final certificate in certificates) {
      if (referenced.contains(certificate.directoryPath)) continue;
      try {
        await _certificates.delete(certificate);
      } catch (_) {
        // A leftover file is harmless; the import failure is what matters.
      }
    }
  }
}

/// A client certificate/key pair used for HTTP mutual TLS.
///
/// The paths point into app-private storage. Key material itself is never
/// copied into this model or into preferences; only the on-disk paths and the
/// optional key password are stored here.
class ClientCertificateConfig {
  /// Human-readable name shown in the connection editor (usually the imported
  /// file name or the certificate's subject CN).
  final String label;

  /// PEM chain for `SecurityContext.useCertificateChain`: the leaf certificate
  /// first, followed by any intermediates/root supplied with it.
  final String certificatePemPath;

  /// PEM private key for `SecurityContext.usePrivateKey`.
  final String privateKeyPemPath;

  /// Password protecting the PEM private key, when it is encrypted.
  final String? privateKeyPassword;

  const ClientCertificateConfig({
    required this.label,
    required this.certificatePemPath,
    required this.privateKeyPemPath,
    this.privateKeyPassword,
  });

  ClientCertificateConfig copyWith({
    String? label,
    String? certificatePemPath,
    String? privateKeyPemPath,
    String? privateKeyPassword,
    bool clearPrivateKeyPassword = false,
  }) {
    return ClientCertificateConfig(
      label: label ?? this.label,
      certificatePemPath: certificatePemPath ?? this.certificatePemPath,
      privateKeyPemPath: privateKeyPemPath ?? this.privateKeyPemPath,
      privateKeyPassword: clearPrivateKeyPassword
          ? null
          : (privateKeyPassword ?? this.privateKeyPassword),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'label': label,
    'certificate_pem_path': certificatePemPath,
    'private_key_pem_path': privateKeyPemPath,
    if (privateKeyPassword != null) 'private_key_password': privateKeyPassword,
  };

  factory ClientCertificateConfig.fromJson(Map<String, dynamic> json) {
    final password = json['private_key_password'] as String?;
    return ClientCertificateConfig(
      label: json['label'] as String,
      certificatePemPath: json['certificate_pem_path'] as String,
      privateKeyPemPath: json['private_key_pem_path'] as String,
      privateKeyPassword: password == null || password.isEmpty
          ? null
          : password,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ClientCertificateConfig &&
        other.label == label &&
        other.certificatePemPath == certificatePemPath &&
        other.privateKeyPemPath == privateKeyPemPath &&
        other.privateKeyPassword == privateKeyPassword;
  }

  @override
  int get hashCode => Object.hash(
    label,
    certificatePemPath,
    privateKeyPemPath,
    privateKeyPassword,
  );
}

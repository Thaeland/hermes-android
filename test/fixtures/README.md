# Test fixtures

`client-cert.pem`, `client-key.pem`, `ca-cert.pem`, and `client-test.p12`
are throwaway test certificates generated once with OpenSSL for the mTLS
tests. They are never real secrets and must not be reused outside this
repository. The `.p12` password is `test-password`.

Additional throwaway fixtures:

- `client-key-encrypted.pem` — `client-key.pem` re-encrypted with OpenSSL
  (`-aes256`); passphrase `key-password`. Used to prove an encrypted PEM key
  keeps its password while an unencrypted one does not.
- `mtls-ca-cert.pem`, `mtls-client-cert.pem`, `mtls-client-key.pem`,
  `mtls-server-cert.pem`, `mtls-server-key.pem` — a self-contained CA plus
  client/server certificates (server SAN `IP:127.0.0.1`, `serverAuth`; client
  `clientAuth`) for the real loopback mTLS tests in
  `test/search_mtls_test.dart`. The server requires a client certificate and
  the client trusts this CA explicitly. The CA private key was discarded after
  signing, so these files cannot issue new certificates.

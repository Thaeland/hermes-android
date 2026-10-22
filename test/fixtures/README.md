# Test fixtures

`client-cert.pem`, `client-key.pem`, `ca-cert.pem`, and `client-test.p12`
are throwaway test certificates generated once with OpenSSL for the mTLS
tests. They are never real secrets and must not be reused outside this
repository. The `.p12` password is `test-password`.

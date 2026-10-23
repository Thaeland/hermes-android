# Hermes mobile-push companion

Opt-in encrypted Web Push delivery for Android UnifiedPush distributors. This is a
separately installed Hermes plugin, **not a running service or a live installation**.
No FCM dependency. Notifications are hints, never approval or execution authority.

See [installation, protocol and security notes](../../docs/mobile-push-server.md).

```sh
export TMPDIR=/absolute/path/to/private/scratch
uv venv --python 3.11 "$TMPDIR/mobile-push-tests"
uv pip install --python "$TMPDIR/mobile-push-tests/bin/python" './server/mobile-push[test]'
"$TMPDIR/mobile-push-tests/bin/python" -m pytest server/mobile-push/tests \
  --basetemp="$TMPDIR/mobile-push-pytest" -q
```

The ordinary suite uses synthetic profile databases, trusted fixture identities and
an explicitly allowed TLS receiver on loopback. Optional real Hermes manager/loader
tests run when `HERMES_AGENT_SOURCE` is set (see the full guide).

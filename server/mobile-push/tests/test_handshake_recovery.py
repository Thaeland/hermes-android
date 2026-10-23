"""Response loss is not a new consent grant; retry only the exact current operation."""

import json

from conftest import PREFIX, end, pending

from mobile_push.store import Store


def confirm(env, registration, hint):
    return env.client.post(
        PREFIX + "/registrations/phone/confirm",
        json={"generation": registration["generation"], "challenge": hint["challenge"]},
    )


def test_lost_put_ack_recovers_exact_response_without_replacing_challenge(env):
    first, hint = pending(env)  # Commit, then discard the response at the client.
    for _ in range(3):
        retry = env.client.put(PREFIX + "/registrations/phone", json=env.body)
        assert retry.status_code == 200
        assert retry.json() == first
    with env.runtime.store.connection() as db:
        rows = db.execute("SELECT payload FROM outbox").fetchall()
    assert [json.loads(row[0]) for row in rows] == [hint]
    assert confirm(env, first, hint).json()["status"] == "active"


def test_lost_confirm_ack_recovers_even_after_expiry_without_deleting_new_events(env):
    first, hint = pending(env)
    assert confirm(env, first, hint).json()["status"] == "active"
    end(env)
    env.runtime.store.clock = lambda: hint["expires_at"] + 1
    # API Store has a separate clock; expiry is persisted so exercise that path too.
    with env.runtime.store.connection() as db:
        db.execute("UPDATE registrations SET challenge_expires=0")
        before = [tuple(row) for row in db.execute("SELECT * FROM outbox")]
    retry = confirm(env, first, hint)
    assert retry.status_code == 200
    assert retry.json() == {"generation": first["generation"], "status": "active"}
    with env.runtime.store.connection() as db:
        assert [tuple(row) for row in db.execute("SELECT * FROM outbox")] == before
    recovered = env.client.put(PREFIX + "/registrations/phone", json=env.body)
    assert recovered.json() == {**first, "status": "active"}


def test_expired_pending_retry_refreshes_proof_not_consent_or_generation(env):
    first, old = pending(env)
    with env.runtime.store.connection() as db:
        db.execute("UPDATE registrations SET challenge_expires=0")
    retry = env.client.put(PREFIX + "/registrations/phone", json=env.body)
    assert retry.status_code == 200
    assert retry.json() == first
    with env.runtime.store.connection() as db:
        queued = db.execute("SELECT payload FROM outbox WHERE done=0").fetchall()
    assert len(queued) == 1
    new = json.loads(queued[0][0])
    assert new["challenge"] != old["challenge"]
    assert new["event_id"] != old["event_id"]
    assert confirm(env, first, old).status_code == 409
    assert confirm(env, first, new).json()["status"] == "active"


def test_same_nonce_changed_body_never_changes_scope_or_endpoint(env):
    first, hint = pending(env)
    for changes in [
        {"endpoint": "https://push.example.test/different"},
        {"event_kinds": ["turn_done"]},
    ]:
        assert (
            env.client.put(
                PREFIX + "/registrations/phone", json={**env.body, **changes}
            ).status_code
            == 409
        )
    assert confirm(env, first, hint).json()["status"] == "active"


def test_superseded_and_revoked_nonces_cannot_be_replayed(env):
    first, old = pending(env)
    newer_body = {**env.body, "registration_nonce": "new_nonce_abcdef01234567"}
    second, new = pending(env, **newer_body)
    assert second["generation"] == first["generation"] + 1
    assert env.client.put(PREFIX + "/registrations/phone", json=env.body).status_code == 409
    assert confirm(env, first, old).status_code == 409
    assert confirm(env, second, new).status_code == 200
    assert env.client.delete(PREFIX + "/registrations/phone").status_code == 200
    assert confirm(env, second, new).status_code == 409
    for body in (env.body, newer_body):
        assert env.client.put(PREFIX + "/registrations/phone", json=body).status_code == 409
    assert env.runtime.store.registration(("fixture", "alice"), "phone")["status"] == "revoked"


def test_recovery_and_nonce_tombstones_survive_server_store_restart(env):
    first, hint = pending(env)
    assert confirm(env, first, hint).status_code == 200
    reopened = Store(env.profile.database)
    assert reopened.put(("fixture", "alice"), "phone", env.body, env.profile.policy()) == {
        **first,
        "status": "active",
    }
    assert (
        reopened.confirm(
            ("fixture", "alice"),
            "phone",
            first["generation"],
            hint["challenge"],
            env.profile.policy(),
        )["status"]
        == "active"
    )
    assert (
        env.client.post(
            PREFIX + "/registrations/phone/confirm",
            json={"generation": first["generation"], "challenge": "wrong" * 8},
        ).status_code
        == 409
    )
    reopened.revoke(("fixture", "alice"), "phone")
    newer = Store(env.profile.database)
    import pytest

    from mobile_push.config import Rejected

    with pytest.raises(Rejected) as error:
        newer.put(("fixture", "alice"), "phone", env.body, env.profile.policy())
    assert error.value.status == 409


def test_retry_still_rechecks_authentication_and_live_policy(env):
    first, hint = pending(env)
    assert confirm(env, first, hint).status_code == 200
    env.config["principals"][0]["session_ids"] = []
    env.save()
    assert confirm(env, first, hint).status_code == 403
    assert env.client.put(PREFIX + "/registrations/phone", json=env.body).status_code == 403
    env.config["enabled"] = False
    env.save()
    assert confirm(env, first, hint).status_code == 503
    env.identity[0] = None
    assert confirm(env, first, hint).status_code == 401

"""Authenticated API. request.state.session is the sole principal authority."""

from __future__ import annotations

import sqlite3
import threading
from collections.abc import Callable
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field

from .config import Profile, Rejected, identifier, validate_keys
from .store import Store
from .transport import validate_endpoint


class BoundedRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def bounded(request):
            if request.method in {"PUT", "POST"}:
                data = bytearray()
                async for chunk in request.stream():
                    data.extend(chunk)
                    if len(data) > 32768:
                        raise HTTPException(413, "Request too large")
                request._body = bytes(data)
            return await handler(request)

        return bounded


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class Keys(StrictModel):
    p256dh: str = Field(min_length=80, max_length=100)
    auth: str = Field(min_length=20, max_length=24)


class Registration(StrictModel):
    endpoint: str = Field(min_length=8, max_length=2048)
    keys: Keys
    registration_nonce: str = Field(pattern=r"^[A-Za-z0-9_-]{16,128}$")
    event_kinds: list[Literal["turn_done", "turn_error", "input", "input_resolved"]] = Field(
        min_length=1, max_length=4
    )
    session_ids: list[str] = Field(min_length=1, max_length=128)


class Confirmation(StrictModel):
    generation: int = Field(ge=1, le=9223372036854775807)
    challenge: str = Field(pattern=r"^[A-Za-z0-9_-]{16,128}$")


def principal(request: Request) -> tuple[str, str]:
    # Never fall back to bearer text, X-User headers, request.state.principal, body or query.
    session = getattr(request.state, "session", None)
    provider, user_id = getattr(session, "provider", None), getattr(session, "user_id", None)
    if not all(isinstance(item, str) and item and len(item) <= 500 for item in (provider, user_id)):
        raise HTTPException(401, "Verified dashboard session required")
    return provider, user_id


def guarded(function, *args):
    try:
        return function(*args)
    except Rejected as error:
        raise HTTPException(error.status, str(error)) from None
    except (OSError, ValueError, TypeError, KeyError, sqlite3.Error):
        raise HTTPException(503, "Mobile push unavailable") from None


Identity = Annotated[tuple[str, str], Depends(principal)]


def create_router(profile_source: Profile | Callable[[], Profile]):
    # The dashboard supplies a factory reading its vetted request-local home.
    # Fixed Profile values remain useful for a single-profile embedded host.
    router = APIRouter(route_class=BoundedRoute)
    stores = {}
    lock = threading.Lock()

    def selected_profile() -> Profile:
        return profile_source() if callable(profile_source) else profile_source

    def store(profile):
        with lock:
            if profile.database not in stores:
                stores[profile.database] = Store(profile.database)
            return stores[profile.database]

    def policy_for(profile, identity):
        policy = profile.policy()
        if not policy.enabled:
            raise Rejected(503, "Mobile push disabled")
        if not policy.admitted(identity):
            raise Rejected(403, "Principal not authorised for mobile push")
        return policy

    @router.get("/capabilities")
    def capabilities(identity: Identity):
        def read():
            profile = selected_profile()
            policy = profile.policy()
            enabled = policy.enabled and policy.admitted(identity)
            return {
                "schema": 1,
                "transports": ["webpush"],
                "enabled": enabled,
                "vapid_public_key": policy.public_key() if enabled else "",
            }

        return guarded(read)

    @router.put("/registrations/{installation_id}")
    def register(installation_id: str, body: Registration, identity: Identity):
        def update():
            profile = selected_profile()
            policy = policy_for(profile, identity)
            if not identifier(installation_id) or not all(
                identifier(sid) for sid in body.session_ids
            ):
                raise Rejected(422, "Invalid installation/session ID")
            if len(set(body.event_kinds)) != len(body.event_kinds) or len(
                set(body.session_ids)
            ) != len(body.session_ids):
                raise Rejected(422, "Duplicate subscription scope")
            # Authorisation before DNS: unauthorised callers cannot use this as a lookup oracle.
            if any(
                not policy.allowed(identity, sid) or not profile.durable(sid)
                for sid in body.session_ids
            ):
                raise Rejected(403, "Session scope not authorised or not durable")
            validate_keys(body.keys.model_dump())
            validate_endpoint(body.endpoint, policy)
            return store(profile).put(identity, installation_id, body.model_dump(), policy)

        return guarded(update)

    @router.post("/registrations/{installation_id}/confirm")
    def confirm(installation_id: str, body: Confirmation, identity: Identity):
        def activate():
            profile = selected_profile()
            policy = policy_for(profile, identity)
            return store(profile).confirm(
                identity, installation_id, body.generation, body.challenge, policy
            )

        return guarded(activate)

    @router.delete("/registrations/{installation_id}")
    def revoke(installation_id: str, identity: Identity):
        def remove():
            # Revocation remains possible after an operator disables/removes a grant.
            return store(selected_profile()).revoke(identity, installation_id)

        return guarded(remove)

    @router.get("/events")
    def events(
        identity: Identity,
        after: int = Query(default=0, ge=0, le=9223372036854775807),
        limit: int = Query(default=100, ge=1, le=200),
    ):
        def read():
            profile = selected_profile()
            policy = policy_for(profile, identity)
            return store(profile).events(identity, after, limit, policy, profile.durable)

        return guarded(read)

    return router

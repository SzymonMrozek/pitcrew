import asyncio
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import CLIENT_ID_HEADER, Session, SessionBroker, create_app


def session(token: str) -> Session:
    return Session(
        accessToken=token,
        refreshToken=f"refresh-{token}",
        expiresAt=datetime(2030, 1, 1, tzinfo=UTC),
    )


def test_empty_session_returns_not_found(tmp_path: Path) -> None:
    client = TestClient(create_app(SessionBroker(tmp_path / "session.json")))

    response = client.get("/session")

    assert response.status_code == 404


def test_device_id_is_shared_across_broker_instances(tmp_path: Path) -> None:
    path = tmp_path / "session.json"

    first = TestClient(create_app(SessionBroker(path))).get("/device-id")
    second = TestClient(create_app(SessionBroker(path))).get("/device-id")

    assert first.status_code == 200
    assert second.json() == first.json()
    assert (tmp_path / "device-id").stat().st_mode & 0o777 == 0o600


def test_login_update_get_and_delete(tmp_path: Path) -> None:
    client = TestClient(create_app(SessionBroker(tmp_path / "session.json")))
    headers = {CLIENT_ID_HEADER: "client-1"}
    stored_session = session("access-1")

    update = client.put(
        "/session",
        headers=headers,
        json={"session": stored_session.model_dump(mode="json", by_alias=True)},
    )
    get = client.get("/session")
    delete = client.delete("/session", headers=headers)

    assert update.status_code == 204
    assert get.status_code == 200
    assert get.json() == stored_session.model_dump(mode="json", by_alias=True)
    assert delete.status_code == 204
    assert client.get("/session").status_code == 404


def test_session_persists_across_broker_instances(tmp_path: Path) -> None:
    path = tmp_path / "session.json"
    stored_session = session("persisted")

    async def scenario() -> Session | None:
        first = SessionBroker(path)
        await first.update_session("client-1", stored_session, None)
        return await SessionBroker(path).get_session()

    assert asyncio.run(scenario()) == stored_session
    assert path.stat().st_mode & 0o777 == 0o600


def test_invalid_persisted_session_fails_startup(tmp_path: Path) -> None:
    path = tmp_path / "session.json"
    path.write_text("not-json")

    with pytest.raises(RuntimeError, match="invalid session file"):
        SessionBroker(path)


def test_get_waits_for_refresh_update(tmp_path: Path) -> None:
    async def scenario() -> Session | None:
        broker = SessionBroker(tmp_path / "session.json", refresh_timeout=1)
        await broker.update_session("login", session("old"), None)
        assert await broker.start_refresh("owner", "old")

        waiting_get = asyncio.create_task(broker.get_session())
        await asyncio.sleep(0)
        assert not waiting_get.done()

        await broker.update_session("owner", session("new"), "old")
        return await waiting_get

    assert asyncio.run(scenario()) == session("new")


def test_get_returns_current_session_after_refresh_timeout(tmp_path: Path) -> None:
    async def scenario() -> Session | None:
        broker = SessionBroker(tmp_path / "session.json", refresh_timeout=0.01)
        old_session = session("old")
        await broker.update_session("login", old_session, None)
        assert await broker.start_refresh("owner", "old")

        return await broker.get_session()

    assert asyncio.run(scenario()) == session("old")


def test_second_starter_uses_updated_session(tmp_path: Path) -> None:
    async def scenario() -> bool:
        broker = SessionBroker(tmp_path / "session.json", refresh_timeout=1)
        await broker.update_session("login", session("old"), None)
        assert await broker.start_refresh("owner", "old")

        waiting_start = asyncio.create_task(broker.start_refresh("waiter", "old"))
        await asyncio.sleep(0)
        assert not waiting_start.done()

        await broker.update_session("owner", session("new"), "old")
        return await waiting_start

    assert asyncio.run(scenario()) is False


def test_only_one_waiter_takes_over_after_timeout(tmp_path: Path) -> None:
    async def scenario() -> tuple[bool, bool]:
        broker = SessionBroker(tmp_path / "session.json", refresh_timeout=0.05)
        await broker.update_session("login", session("old"), None)
        assert await broker.start_refresh("old-owner", "old")

        waiter_1 = asyncio.create_task(broker.start_refresh("waiter-1", "old"))
        waiter_2 = asyncio.create_task(broker.start_refresh("waiter-2", "old"))
        done, pending = await asyncio.wait(
            {waiter_1, waiter_2},
            timeout=0.2,
            return_when=asyncio.FIRST_COMPLETED,
        )
        assert len(done) == 1
        assert len(pending) == 1

        winner_task = done.pop()
        winner_id = "waiter-1" if winner_task is waiter_1 else "waiter-2"
        assert winner_task.result() is True
        await broker.update_session(winner_id, session("new"), "old")

        return await waiter_1, await waiter_2

    assert sorted(asyncio.run(scenario())) == [False, True]


def test_waiter_takes_over_after_timeout_and_old_owner_is_rejected(tmp_path: Path) -> None:
    async def scenario() -> tuple[bool, bool, bool]:
        broker = SessionBroker(tmp_path / "session.json", refresh_timeout=0.01)
        await broker.update_session("login", session("old"), None)
        assert await broker.start_refresh("old-owner", "old")

        takeover = await broker.start_refresh("new-owner", "old")
        stale_update = await broker.update_session("old-owner", session("stale"), "old")
        current_update = await broker.update_session("new-owner", session("new"), "old")
        return takeover, stale_update, current_update

    assert asyncio.run(scenario()) == (True, False, True)


def test_conditional_delete_cannot_remove_newer_session(tmp_path: Path) -> None:
    async def scenario() -> tuple[bool, Session | None]:
        broker = SessionBroker(tmp_path / "session.json", refresh_timeout=1)
        await broker.update_session("login", session("old"), None)
        assert await broker.start_refresh("owner", "old")
        await broker.update_session("login", session("new"), None)

        deleted = await broker.delete_session("owner", "old")
        return deleted, await broker.get_session()

    assert asyncio.run(scenario()) == (False, session("new"))


def test_client_id_header_is_configurable(tmp_path: Path) -> None:
    client = TestClient(create_app(SessionBroker(tmp_path / "session.json")))

    response = client.delete("/session", headers={"X-Some-Other-Header": "client-1"})
    accepted = client.delete("/session", headers={CLIENT_ID_HEADER: "client-1"})

    assert response.status_code == 422
    assert accepted.status_code == 204

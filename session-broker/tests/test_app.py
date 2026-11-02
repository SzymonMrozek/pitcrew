import asyncio
from concurrent.futures import ThreadPoolExecutor
import time
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


def test_environments_isolate_sessions_refresh_and_logout(tmp_path: Path) -> None:
    with TestClient(create_app(SessionBroker(tmp_path / "session.json"))) as client:
        owner = {CLIENT_ID_HEADER: "same-client"}
        for environment in ("production", "development"):
            assert client.put("/sessions", params={"environment": environment}, headers=owner,
                              json={"session": session("same-token").model_dump(mode="json", by_alias=True)}).status_code == 204
            assert client.post("/sessions/refresh/start", params={"environment": environment}, headers=owner,
                               json={"replacingAccessToken": "same-token"}).json() == {"shouldRefresh": True}

        # Each environment needs its own lease even when both the client and token are identical.
        assert client.put("/sessions", params={"environment": "development"}, headers=owner,
                          json={"session": session("dev-refreshed").model_dump(mode="json", by_alias=True),
                                "replacingAccessToken": "same-token"}).status_code == 204
        assert client.put("/sessions", params={"environment": "production"}, headers=owner,
                          json={"session": session("prod-refreshed").model_dump(mode="json", by_alias=True),
                                "replacingAccessToken": "same-token"}).status_code == 204
        assert client.delete("/sessions", params={"environment": "development"}, headers=owner).status_code == 204
        assert client.get("/sessions", params={"environment": "development"}).status_code == 404
        assert client.get("/sessions", params={"environment": "production"}).json()["accessToken"] == "prod-refreshed"


def test_environment_cannot_use_another_environments_refresh_lease(tmp_path: Path) -> None:
    with TestClient(create_app(SessionBroker(tmp_path / "session.json"))) as client:
        owner = {CLIENT_ID_HEADER: "owner"}
        for environment in ("production", "development"):
            assert client.put("/sessions", params={"environment": environment}, headers=owner,
                              json={"session": session("same-token").model_dump(mode="json", by_alias=True)}).status_code == 204
        assert client.post("/sessions/refresh/start", params={"environment": "production"}, headers=owner,
                           json={"replacingAccessToken": "same-token"}).json() == {"shouldRefresh": True}
        assert client.put("/sessions", params={"environment": "development"}, headers=owner,
                          json={"session": session("wrong").model_dump(mode="json", by_alias=True),
                                "replacingAccessToken": "same-token"}).status_code == 409
        assert client.request("DELETE", "/sessions", params={"environment": "development"}, headers=owner,
                              json={"replacingAccessToken": "same-token"}).status_code == 409
        assert client.get("/sessions", params={"environment": "development"}).json()["accessToken"] == "same-token"


def test_environment_sessions_and_shared_device_id_persist(tmp_path: Path) -> None:
    path = tmp_path / "session.json"
    with TestClient(create_app(SessionBroker(path))) as client:
        identity = client.get("/device-id").json()
        for environment in ("production", "development", "staging-2"):
            assert client.put("/sessions", params={"environment": environment}, headers={CLIENT_ID_HEADER: "login"},
                              json={"session": session(environment).model_dump(mode="json", by_alias=True)}).status_code == 204

    with TestClient(create_app(SessionBroker(path))) as restarted:
        for environment in ("production", "development", "staging-2"):
            assert restarted.get("/sessions", params={"environment": environment}).json()["accessToken"] == environment
        assert restarted.get("/device-id").json() == identity
        # Older clients continue to read the production session from the original file.
        assert restarted.get("/session").json()["accessToken"] == "production"
        assert Session.model_validate_json(path.read_text()) == session("production")
        assert (tmp_path / "session.development.json").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("environment", ["", "../production", "a/b", "a.b", "Production", "a" * 65, "dev\n"])
def test_invalid_environment_is_rejected(tmp_path: Path, environment: str) -> None:
    with TestClient(create_app(SessionBroker(tmp_path / "session.json"))) as client:
        assert client.get("/sessions", params={"environment": environment}).status_code == 422
        assert client.put("/sessions", params={"environment": environment}, headers={CLIENT_ID_HEADER: "login"},
                          json={"session": session("bad").model_dump(mode="json", by_alias=True)}).status_code == 422
    assert list(tmp_path.glob("*.json")) == []


def test_corrupt_environment_session_fails_startup(tmp_path: Path) -> None:
    (tmp_path / "session.development.json").write_text("not-json")
    with pytest.raises(RuntimeError, match="invalid session file"):
        create_app(SessionBroker(tmp_path / "session.json"))


def test_health_advertises_environment_support(tmp_path: Path) -> None:
    client = TestClient(create_app(SessionBroker(tmp_path / "session.json")))
    assert client.get("/health").json() == {"status": "ok", "environments": True}


def test_concurrent_first_requests_share_one_environment_broker(tmp_path: Path, monkeypatch) -> None:
    created = []

    class CountingBroker(SessionBroker):
        def __init__(self, *args, **kwargs):
            created.append(self)
            time.sleep(0.01)
            super().__init__(*args, **kwargs)

    root = SessionBroker(tmp_path / "session.json")
    monkeypatch.setattr("app.SessionBroker", CountingBroker)
    with TestClient(create_app(root)) as client, ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(lambda _: client.get("/sessions", params={"environment": "new-env"}), range(16)))
        assert all(response.status_code == 404 for response in responses)
    assert len(created) == 1

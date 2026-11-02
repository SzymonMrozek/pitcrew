import asyncio
import os
import re
import time
from uuid import UUID, uuid4
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, ConfigDict


CLIENT_ID_HEADER = os.getenv("SESSION_BROKER_CLIENT_ID_HEADER", "X-Session-Client-ID")
ENVIRONMENT_PATTERN = r"^[a-z0-9][a-z0-9_-]{0,63}$"
REFRESH_TIMEOUT_SECONDS = float(os.getenv("SESSION_BROKER_REFRESH_TIMEOUT", "45"))


def camel_case(name: str) -> str:
    first, *rest = name.split("_")
    return first + "".join(word.title() for word in rest)


class APIModel(BaseModel):
    model_config = ConfigDict(alias_generator=camel_case, populate_by_name=True)


class Session(APIModel):
    model_config = ConfigDict(frozen=True)

    access_token: str
    refresh_token: str
    expires_at: datetime


class DeviceId(APIModel):
    model_config = ConfigDict(frozen=True)

    device_id: str


class StartRefreshRequest(APIModel):
    replacing_access_token: str


class StartRefreshResponse(APIModel):
    should_refresh: bool


class UpdateSessionRequest(APIModel):
    session: Session
    replacing_access_token: str | None = None


class DeleteSessionRequest(APIModel):
    replacing_access_token: str | None = None


@dataclass(frozen=True)
class RefreshOwner:
    client_id: str
    replacing_access_token: str
    deadline: float


class SessionBroker:
    def __init__(
        self,
        storage_path: Path,
        refresh_timeout: float = REFRESH_TIMEOUT_SECONDS,
    ) -> None:
        self._storage_path = storage_path
        self._device_id_path = storage_path.with_name("device-id")
        self._refresh_timeout = refresh_timeout
        self._condition = asyncio.Condition()
        self._session = self._load_session()
        self._generation = 0
        self._refresh_owner: RefreshOwner | None = None
        self._device_id = self._load_or_create_device_id()

    def get_device_id(self) -> str:
        return self._device_id

    async def get_session(self) -> Session | None:
        async with self._condition:
            while self._refresh_owner is not None:
                remaining = self._refresh_owner.deadline - time.monotonic()
                if remaining <= 0:
                    self._refresh_owner = None
                    self._condition.notify_all()
                    break

                try:
                    await asyncio.wait_for(self._condition.wait(), timeout=remaining)
                except TimeoutError:
                    pass

            return self._session

    async def start_refresh(self, client_id: str, replacing_access_token: str) -> bool:
        async with self._condition:
            observed_generation = self._generation

            while True:
                if self._session is None:
                    raise LookupError("session does not exist")

                if self._generation != observed_generation or self._session.access_token != replacing_access_token:
                    return False

                now = time.monotonic()
                owner = self._refresh_owner
                if owner is None or owner.deadline <= now:
                    self._refresh_owner = RefreshOwner(
                        client_id=client_id,
                        replacing_access_token=replacing_access_token,
                        deadline=now + self._refresh_timeout,
                    )
                    return True

                if owner.client_id == client_id:
                    return True

                try:
                    await asyncio.wait_for(self._condition.wait(), timeout=owner.deadline - now)
                except TimeoutError:
                    pass

    async def update_session(
        self,
        client_id: str,
        session: Session,
        replacing_access_token: str | None,
    ) -> bool:
        async with self._condition:
            if replacing_access_token is not None and not self._owns_current_refresh(
                client_id,
                replacing_access_token,
            ):
                return False

            self._persist_session(session)
            self._session = session
            self._generation += 1
            self._refresh_owner = None
            self._condition.notify_all()
            return True

    async def delete_session(self, client_id: str, replacing_access_token: str | None) -> bool:
        async with self._condition:
            if replacing_access_token is not None and not self._owns_current_refresh(
                client_id,
                replacing_access_token,
            ):
                return False

            self._delete_persisted_session()
            self._session = None
            self._generation += 1
            self._refresh_owner = None
            self._condition.notify_all()
            return True

    def _owns_current_refresh(self, client_id: str, replacing_access_token: str) -> bool:
        owner = self._refresh_owner
        return (
            owner is not None
            and owner.client_id == client_id
            and owner.replacing_access_token == replacing_access_token
            and owner.deadline > time.monotonic()
            and self._session is not None
            and self._session.access_token == replacing_access_token
        )

    def _load_session(self) -> Session | None:
        if not self._storage_path.exists():
            return None

        try:
            return Session.model_validate_json(self._storage_path.read_text())
        except Exception as error:
            raise RuntimeError(f"invalid session file: {self._storage_path}") from error

    def _persist_session(self, session: Session) -> None:
        self._storage_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = self._storage_path.with_suffix(".tmp")
        temporary_path.write_text(session.model_dump_json(by_alias=True))
        temporary_path.chmod(0o600)
        os.replace(temporary_path, self._storage_path)

    def _delete_persisted_session(self) -> None:
        self._storage_path.unlink(missing_ok=True)

    def _load_or_create_device_id(self) -> str:
        if self._device_id_path.exists():
            try:
                return str(UUID(self._device_id_path.read_text().strip()))
            except (ValueError, OSError) as error:
                raise RuntimeError(f"invalid device ID file: {self._device_id_path}") from error

        device_id = str(uuid4())
        self._device_id_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = self._device_id_path.with_suffix(".tmp")
        temporary_path.write_text(device_id)
        temporary_path.chmod(0o600)
        os.replace(temporary_path, self._device_id_path)
        return device_id


def create_app(broker: SessionBroker | None = None) -> FastAPI:
    app = FastAPI(title="Simulator Session Broker")
    session_broker = broker or SessionBroker(Path(os.getenv("SESSION_FILE", "/data/session.json")))
    storage_path = session_broker._storage_path
    brokers = {"production": session_broker}

    def load_environment(environment: str) -> SessionBroker:
        if environment not in brokers:
            path = storage_path.with_name(f"{storage_path.stem}.{environment}{storage_path.suffix}")
            brokers[environment] = SessionBroker(path, refresh_timeout=session_broker._refresh_timeout)
        return brokers[environment]

    async def broker_for_environment(
        environment: Annotated[str, Query(pattern=ENVIRONMENT_PATTERN)] = "production",
    ) -> SessionBroker:
        # Stay on the event loop so concurrent first requests cannot create competing brokers.
        return load_environment(environment)

    # Validate all persisted environments at startup, including ones nobody has requested yet.
    for path in storage_path.parent.glob(f"{storage_path.stem}.*{storage_path.suffix}"):
        environment = path.name.removeprefix(f"{storage_path.stem}.").removesuffix(storage_path.suffix)
        if not re.fullmatch(ENVIRONMENT_PATTERN, environment) or environment == "production":
            raise RuntimeError(f"invalid environment session file: {path}")
        load_environment(environment)

    @app.get("/health")
    async def health() -> dict[str, str | bool]:
        return {"status": "ok", "environments": True}

    @app.get("/device-id", response_model=DeviceId)
    async def get_device_id() -> DeviceId:
        return DeviceId(deviceId=session_broker.get_device_id())

    @app.get("/session", response_model=Session)
    @app.get("/sessions", response_model=Session)
    async def get_session(broker: Annotated[SessionBroker, Depends(broker_for_environment)]) -> Session:
        session = await broker.get_session()
        if session is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="session does not exist")
        return session

    @app.post("/refresh/start", response_model=StartRefreshResponse)
    @app.post("/sessions/refresh/start", response_model=StartRefreshResponse)
    async def start_refresh(
        body: StartRefreshRequest,
        broker: Annotated[SessionBroker, Depends(broker_for_environment)],
        client_id: Annotated[str, Header(alias=CLIENT_ID_HEADER)],
    ) -> StartRefreshResponse:
        try:
            should_refresh = await broker.start_refresh(
                client_id,
                body.replacing_access_token,
            )
        except LookupError as error:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error

        return StartRefreshResponse(shouldRefresh=should_refresh)

    @app.put("/session", status_code=status.HTTP_204_NO_CONTENT)
    @app.put("/sessions", status_code=status.HTTP_204_NO_CONTENT)
    async def update_session(
        body: UpdateSessionRequest,
        broker: Annotated[SessionBroker, Depends(broker_for_environment)],
        client_id: Annotated[str, Header(alias=CLIENT_ID_HEADER)],
    ) -> Response:
        updated = await broker.update_session(
            client_id,
            body.session,
            body.replacing_access_token,
        )
        if not updated:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="client does not own the current refresh",
            )
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.delete("/session", status_code=status.HTTP_204_NO_CONTENT)
    @app.delete("/sessions", status_code=status.HTTP_204_NO_CONTENT)
    async def delete_session(
        request: Request,
        broker: Annotated[SessionBroker, Depends(broker_for_environment)],
        client_id: Annotated[str, Header(alias=CLIENT_ID_HEADER)],
    ) -> Response:
        raw_body = await request.body()
        body = DeleteSessionRequest.model_validate_json(raw_body) if raw_body else DeleteSessionRequest()
        replacing_access_token = body.replacing_access_token
        deleted = await broker.delete_session(client_id, replacing_access_token)
        if not deleted:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="client does not own the current refresh",
            )
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return app


app = create_app()

# Builds a release, then runs it under Litestream, which restores the database
# from the bucket on first boot and streams every change back to it.
ARG BUILDER_IMAGE=hexpm/elixir:1.20.4-erlang-28.5.0.7-debian-trixie-20261005-slim
ARG RUNNER_IMAGE=debian:trixie-20261005-slim
ARG LITESTREAM_VERSION=0.5.17

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix assets.deploy && mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS litestream
ARG LITESTREAM_VERSION
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
  case "${TARGETARCH}" in arm64) arch=arm64 ;; amd64) arch=x86_64 ;; *) echo "unsupported ${TARGETARCH}"; exit 1 ;; esac; \
  base="https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}"; \
  file="litestream-${LITESTREAM_VERSION}-linux-${arch}.tar.gz"; \
  curl -fsSLO "${base}/${file}"; \
  curl -fsSL "${base}/checksums.txt" | grep " ${file}\$" | sha256sum -c -; \
  tar -xzf "${file}" -C /usr/local/bin litestream

FROM ${RUNNER_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod PHX_SERVER=true DATABASE_PATH=/data/build_distro.db

WORKDIR /app
RUN useradd --create-home app && mkdir /data && chown app /data
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream
COPY --from=builder --chown=app /app/_build/prod/rel/build_distro ./
COPY litestream.yml /etc/litestream.yml

USER app
VOLUME /data
EXPOSE 4000
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s CMD curl -fsS http://127.0.0.1:4000/health || exit 1
CMD ["/app/bin/start"]

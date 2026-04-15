# syntax=docker/dockerfile:1
# Multi-stage build: compile release in builder, run in minimal image
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241202-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ─── Frontend build ──────────────────────────────────────────────────────
FROM oven/bun:1.3 AS frontend

WORKDIR /frontend
COPY frontend/package.json frontend/bun.lockb ./
RUN bun install --frozen-lockfile
COPY frontend/ ./
ARG VITE_AUTH_PROVIDER="local"
ARG VITE_CLERK_PUBLISHABLE_KEY=""
ENV VITE_AUTH_PROVIDER=$VITE_AUTH_PROVIDER
ENV VITE_CLERK_PUBLISHABLE_KEY=$VITE_CLERK_PUBLISHABLE_KEY
RUN bun run build

# ─── Elixir build ────────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -y && apt-get install -y build-essential git

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Fetch deps — cache mount means only changed deps are re-downloaded
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/app/deps,id=mix-deps \
    mix deps.get --only $MIX_ENV

# Compile deps — cache mount preserves compiled artifacts between builds
RUN mkdir -p config
COPY config/config.exs config/runtime.exs config/prod.exs config/
RUN --mount=type=cache,target=/app/deps,id=mix-deps \
    --mount=type=cache,target=/app/_build,id=mix-build \
    mix deps.compile

# Compile app code
COPY priv priv
COPY --from=frontend /priv/static/app priv/static/app
COPY lib lib
COPY config/runtime.exs config/

# Build release — no _build cache mount here; BuildKit's COPY-from-builder
# layer cache doesn't see filesystem changes made alongside cache mounts,
# causing stale release binaries. deps cache is fine (read-only here).
RUN --mount=type=cache,target=/app/deps,id=mix-deps \
    mix compile --force && mix release && \
    cp -r /app/_build/prod/rel/engram /app/_release

# ─── Runner ───────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_release ./

USER nobody

EXPOSE 4000

ENV PHX_SERVER=true

CMD /app/bin/engram eval "Engram.Release.migrate()" && exec /app/bin/engram start

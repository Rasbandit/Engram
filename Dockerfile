# Multi-stage build: compile release in builder, run in minimal image
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241202-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ─── Frontend build ──────────────────────────────────────────────────────
FROM node:20-slim AS frontend

WORKDIR /frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
ARG VITE_CLERK_PUBLISHABLE_KEY=""
ENV VITE_CLERK_PUBLISHABLE_KEY=$VITE_CLERK_PUBLISHABLE_KEY
RUN npm run build

# ─── Elixir build ────────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

# Install build tools
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Fetch deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

# Compile deps
RUN mkdir config
COPY config/config.exs config/runtime.exs config/prod.exs config/
RUN mix deps.compile

# Build release
COPY priv priv
COPY --from=frontend /priv/static/app priv/static/app
COPY lib lib
RUN mix compile

# Generate release
COPY config/runtime.exs config/
RUN mix release

# ─── Runner ───────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# Run migrations then start the app
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/engram ./

USER nobody

EXPOSE 4000

ENV PHX_SERVER=true

# Run migrations then start server
CMD /app/bin/engram eval "Engram.Release.migrate()" && exec /app/bin/engram start

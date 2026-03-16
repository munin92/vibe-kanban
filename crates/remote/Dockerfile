# syntax=docker/dockerfile:1.6

ARG APP_NAME=remote
ARG FEATURES=""
ARG VITE_RELAY_API_BASE_URL=""
ARG VITE_PUBLIC_REACT_VIRTUOSO_LICENSE_KEY=""

# ── Stage 1: Frontend builder ─────────────────────────────────────────────
FROM node:24-alpine AS fe-builder
ARG VITE_RELAY_API_BASE_URL
ARG VITE_PUBLIC_REACT_VIRTUOSO_LICENSE_KEY

WORKDIR /repo

ENV VITE_RELAY_API_BASE_URL=${VITE_RELAY_API_BASE_URL}
ENV VITE_PUBLIC_REACT_VIRTUOSO_LICENSE_KEY=${VITE_PUBLIC_REACT_VIRTUOSO_LICENSE_KEY}

# hadolint ignore=DL3016
RUN npm install -g corepack@latest && corepack enable

# ── Node dependency cache layer ───────────────────────────────────────────
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY packages/remote-web/package.json ./packages/remote-web/
COPY packages/web-core/package.json ./packages/web-core/
COPY packages/ui/package.json ./packages/ui/

RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile

COPY packages/ packages/
COPY shared/ shared/

RUN pnpm -C packages/remote-web build

# ── Stage 2: cargo-chef planner ───────────────────────────────────────────
# cargo chef prepare must run from the workspace root of crates/remote
# (it is a separate workspace, excluded from the main Cargo.toml)
FROM rust:1.93-slim-bookworm AS planner

RUN apt-get update \
  && apt-get install -y --no-install-recommends pkg-config libssl-dev \
  && rm -rf /var/lib/apt/lists/*

RUN cargo install cargo-chef --locked

WORKDIR /app/crates/remote

COPY crates/remote/Cargo.toml crates/remote/Cargo.lock ./

# cargo chef prepare auto-discovers the workspace from the current directory
RUN cargo chef prepare --recipe-path /app/recipe.json

# ── Stage 3: Rust builder ─────────────────────────────────────────────────
FROM rust:1.93-slim-bookworm AS builder
ARG APP_NAME
ARG FEATURES
ARG POSTHOG_API_KEY=""
ARG POSTHOG_API_ENDPOINT=""
ARG SENTRY_DSN_REMOTE=""

ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
ENV POSTHOG_API_KEY=${POSTHOG_API_KEY}
ENV POSTHOG_API_ENDPOINT=${POSTHOG_API_ENDPOINT}
ENV SENTRY_DSN_REMOTE=${SENTRY_DSN_REMOTE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates git openssh-client \
  && rm -rf /var/lib/apt/lists/*

RUN cargo install cargo-chef --locked

WORKDIR /app/crates/remote

# ── Rust dependency cache layer ───────────────────────────────────────────
COPY --from=planner /app/recipe.json /app/recipe.json
COPY crates/remote/Cargo.toml crates/remote/Cargo.lock ./

# Strip private billing dep when building without FEATURES (self-hosted)
RUN if [ -z "${FEATURES}" ]; then \
      sed -i '/^billing = {.*vibe-kanban-private.*/d' Cargo.toml; \
      sed -i '/^# private crate for billing/d' Cargo.toml; \
      sed -i '/^vk-billing = \["dep:billing"\]/d' Cargo.toml; \
      rm -f Cargo.lock; \
    fi

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo chef cook --release --recipe-path /app/recipe.json ${FEATURES:+--features ${FEATURES}}

# ── Full source build ─────────────────────────────────────────────────────
WORKDIR /app

COPY crates/remote ./crates/remote
COPY shared ./shared
COPY assets ./assets

RUN mkdir -p /app/bin

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/crates/remote/target \
    --mount=type=ssh \
    cargo build ${FEATURES:+--locked} --release --manifest-path crates/remote/Cargo.toml ${FEATURES:+--features ${FEATURES}} \
 && cp crates/remote/target/release/${APP_NAME} /app/bin/${APP_NAME}

# ── Stage 4: minimal runtime ──────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime
ARG APP_NAME

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libssl3 wget git \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --system --create-home --uid 10001 appuser

WORKDIR /srv

COPY --from=builder /app/bin/${APP_NAME} /usr/local/bin/${APP_NAME}
COPY --from=fe-builder /repo/packages/remote-web/dist /srv/static

USER appuser

ENV SERVER_LISTEN_ADDR=0.0.0.0:8081 \
    RUST_LOG=info

EXPOSE 8081

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["wget","--spider","-q","http://127.0.0.1:8081/v1/health"]

ENTRYPOINT ["/usr/local/bin/remote"]

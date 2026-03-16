# ── Stage 1: cargo-chef planner ───────────────────────────────────────────
# Uses node:24-alpine + rustup (no official rust:nightly alpine image exists).
# Extracts dependency recipe from Cargo manifests — re-runs only on Cargo changes.
FROM node:24-alpine AS planner

# hadolint ignore=DL3018
RUN apk add --no-cache musl-dev build-base curl

ENV RUSTFLAGS="-C target-feature=-crt-static"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain nightly-2025-12-04
ENV PATH="/root/.cargo/bin:${PATH}"

RUN cargo install cargo-chef --locked

WORKDIR /app
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates/ ./crates/
RUN cargo chef prepare --recipe-path recipe.json

# ── Stage 2: full builder (Node + Rust) ───────────────────────────────────
FROM node:24-alpine AS builder

# hadolint ignore=DL3018
RUN apk add --no-cache \
    build-base \
    perl \
    llvm-dev \
    clang-dev \
    glib-dev \
    curl

ENV RUSTFLAGS="-C target-feature=-crt-static"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain nightly-2025-12-04
ENV PATH="/root/.cargo/bin:${PATH}"

RUN cargo install cargo-chef --locked

# hadolint ignore=DL3016
RUN npm install -g pnpm@10.13.1

ARG POSTHOG_API_KEY
ARG POSTHOG_API_ENDPOINT
ENV VITE_PUBLIC_POSTHOG_KEY=$POSTHOG_API_KEY
ENV VITE_PUBLIC_POSTHOG_HOST=$POSTHOG_API_ENDPOINT

WORKDIR /app

# ── Rust dependency cache layer ───────────────────────────────────────────
# Re-runs only when Cargo.toml / Cargo.lock changes, not on source changes
COPY --from=planner /app/recipe.json recipe.json
COPY Cargo.toml Cargo.lock rust-toolchain.toml .cargo* ./
RUN cargo chef cook --release --recipe-path recipe.json

# ── Node dependency cache layer ───────────────────────────────────────────
# Re-runs only when pnpm-lock.yaml / package.json changes
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY packages/local-web/package.json ./packages/local-web/
COPY packages/web-core/package.json ./packages/web-core/
COPY packages/ui/package.json ./packages/ui/
COPY npx-cli/package.json ./npx-cli/
RUN pnpm install --frozen-lockfile

# ── Full source + build ───────────────────────────────────────────────────
COPY . .

RUN npm run generate-types
RUN cd packages/local-web && pnpm run build
RUN cargo build --release --bin server

# ── Stage 3: minimal runtime ──────────────────────────────────────────────
FROM alpine:3.23 AS runtime

# hadolint ignore=DL3018
RUN apk add --no-cache \
    ca-certificates \
    tini \
    libgcc \
    wget && \
    addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

COPY --from=builder /app/target/release/server /usr/local/bin/server

RUN mkdir -p /repos && \
    chown -R appuser:appgroup /repos

USER appuser

ENV HOST=0.0.0.0
ENV PORT=3000
EXPOSE 3000

WORKDIR /repos

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider "http://${HOST:-localhost}:${PORT:-3000}" || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["server"]

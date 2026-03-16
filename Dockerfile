# renovate: datasource=github-releases depName=BloopAI/vibe-kanban
ARG VERSION=v0.1.31-20260316163135
# renovate: datasource=github-releases depName=BloopAI/vibe-kanban
ARG BINARY_SHA256=55957726b58f768eaf264763fa3a32c2de9853df4324682c406a3e7f9a5570f5

# ── Stage 1: download pre-built binaries + frontend dist ─────────────────
# No Rust or Node compilation needed — Bloop publishes ready-made binaries
# for every release via https://npm-cdn.vibekanban.com
FROM alpine:3.23 AS downloader
ARG VERSION
ARG BINARY_SHA256

# hadolint ignore=DL3018
RUN apk add --no-cache curl unzip ca-certificates

# Download pre-built server binary and verify SHA256
RUN curl -fsSL "https://npm-cdn.vibekanban.com/binaries/${VERSION}/linux-x64/vibe-kanban.zip" \
      -o /tmp/vibe-kanban.zip && \
    echo "${BINARY_SHA256}  /tmp/vibe-kanban.zip" | sha256sum -c - && \
    unzip /tmp/vibe-kanban.zip -d /tmp/ && \
    chmod +x /tmp/vibe-kanban

# Download frontend dist from GitHub release
RUN curl -fsSL "https://github.com/BloopAI/vibe-kanban/releases/download/${VERSION}/vibe-kanban-${VERSION}.zip" \
      -o /tmp/dist.zip && \
    unzip /tmp/dist.zip -d /tmp/dist/

# ── Stage 2: minimal runtime image ───────────────────────────────────────
FROM alpine:3.23 AS runtime

# hadolint ignore=DL3018
RUN apk add --no-cache \
    ca-certificates \
    tini \
    libgcc \
    wget && \
    addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

COPY --from=downloader /tmp/vibe-kanban /usr/local/bin/server
COPY --from=downloader /tmp/dist/ /dist/

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

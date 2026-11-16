# syntax=docker/dockerfile:1.7

ARG RUST_VERSION=1.97.1
ARG NODE_VERSION=22

FROM node:${NODE_VERSION}-bookworm-slim AS frontend-builder
WORKDIR /src
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
COPY package.json package-lock.json .npmrc tsconfig.json tsconfig.projects.json ./
COPY apps ./apps
COPY packages ./packages
RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts && \
    npm run build --workspace=@opensymphony/web

FROM rust:${RUST_VERSION}-bookworm AS rust-builder
WORKDIR /src
ENV CARGO_BUILD_JOBS=2
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        clang \
        cmake \
        libclang-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock rust-toolchain.toml rustfmt.toml clippy.toml ./
COPY src ./src
COPY crates ./crates
COPY tools ./tools
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/target \
    cargo build --locked --release && \
    cp /src/target/release/opensymphony /usr/local/bin/opensymphony

FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ARG CODEX_CLI_VERSION=0.138.0
LABEL org.opencontainers.image.title="OpenSymphony" \
      org.opencontainers.image.description="OpenSymphony orchestrator with the official Codex CLI"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gh \
        git \
        git-lfs \
        jq \
        openssh-client \
        procps \
        ripgrep \
        tini \
        unzip \
    && npm install --global "@openai/codex@${CODEX_CLI_VERSION}" \
    && npm cache clean --force \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 opensymphony \
    && useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash opensymphony \
    && install -d -o opensymphony -g opensymphony \
        /config \
        /config/.opensymphony \
        /data \
        /workspaces \
        /home/opensymphony/.codex \
        /home/opensymphony/.config \
        /home/opensymphony/.ssh

COPY --from=rust-builder /usr/local/bin/opensymphony /usr/local/bin/opensymphony
COPY --chown=opensymphony:opensymphony deploy/config.yaml /config/config.yaml
COPY --chown=opensymphony:opensymphony deploy/WORKFLOW.md /config/WORKFLOW.md
COPY --chown=opensymphony:opensymphony deploy/codex-config.toml /home/opensymphony/.codex/config.toml

ENV HOME=/home/opensymphony \
    CODEX_HOME=/home/opensymphony/.codex \
    XDG_CONFIG_HOME=/home/opensymphony/.config \
    OPENSYMPHONY_CODEX_BIN=/usr/local/bin/codex
WORKDIR /config
USER opensymphony
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["opensymphony", "run", "--config", "/config/config.yaml"]

FROM caddy:2.10.2-alpine AS web
COPY deploy/Caddyfile /etc/caddy/Caddyfile
COPY --from=frontend-builder /src/apps/web/dist /srv

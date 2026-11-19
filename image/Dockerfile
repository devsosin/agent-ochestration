# syntax=docker/dockerfile:1
# Agent image. Build with `bin/proj build` (tags agent-hub:base, agent-hub:rust).

FROM node:22-bookworm-slim AS base
ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq ripgrep less procps openssh-client \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 # Docker CLI + compose; they reach the host only through the project's proxy (DOCKER_HOST=tcp://docker:2375).
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends gh docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && npm cache clean --force

COPY managed-settings.json /etc/claude-code/managed-settings.json
COPY gitconfig /etc/gitconfig
COPY profile.sh /etc/profile.d/agent-hub.sh
COPY agent-run /usr/local/bin/agent-run
COPY mcp.json /etc/agent-hub/mcp.json
RUN chmod 755 /usr/local/bin/agent-run \
 && echo '. /etc/profile.d/agent-hub.sh' >> /etc/bash.bashrc \
 # Mount points owned by node so named volumes copy that ownership on first mount.
 && install -d -o node -g node /home/node/.claude /usr/local/cargo/registry /usr/local/cargo/git /var/agent-hub/tasks

# Updates come from rebuilding the image, not from inside a running container.
ENV DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_SYNC_PLUGIN_INSTALL=1 \
    CLAUDE_CONFIG_DIR=/home/node/.claude

USER node
WORKDIR /home/node
CMD ["sleep", "infinity"]


FROM base AS rust
USER root
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --component rustfmt,clippy --no-modify-path \
 && chown -R node:node /usr/local/cargo /usr/local/rustup
USER node

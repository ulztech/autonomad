# Autonomad v1 — autonomous GitHub issue developer.
#
# Image bakes: node (opencode runtime), gh CLI, git, pwsh (tick loop),
# sqlite3 (learning store), docker CLI (per-issue sandbox provisioning),
# the marketplace agents and shell adapters.
#
# Build:   docker build -t autonomad:v1 .
# Run:     see scripts/Start-Autonomad.ps1
#          docker run --env-file .env --name autonomad \
#            -v /var/run/docker.sock:/var/run/docker.sock \
#            -v autonomad-data:/data \
#            autonomad:v1
#
# The host AIOS brain is mounted by Start/Provision, NOT baked into the image,
# because the brain path is host-specific (AIOS_BRAIN_PATH from .env).

FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    AUTONOMAD_HOME=/opt/autonomad \
    AUTONOMAD_DATA=/data \
    PATH="/opt/autonomad/scripts:/opt/autonomad/adapters:${PATH}"

# --- System deps: git, bash, curl, docker CLI, sqlite3, pwsh, gh ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        sqlite3 \
        docker.io \
        openssh-client \
        apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# --- PowerShell 7 (tick loop is pwsh; must match what scripts were tested with) ---
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/repos/microsoft-debian-bookworm-prod bookworm main" \
        > /etc/apt/sources.list.d/microsoft.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# --- .NET 8 SDK (dev sandbox builds/tests target repos; HRSystem-Legacy is net8.0) ---
# dotnet-install.sh pulls the pinned channel; symlink lands on PATH so the
# sandbox's `dotnet build` / `dotnet test` commands work out of the box.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    PATH="/usr/share/dotnet:${PATH}"
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet \
    && rm /tmp/dotnet-install.sh \
    && /usr/share/dotnet/dotnet --list-sdks

# --- GitHub CLI ---
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- opencode (dev harness; repo.config harness decides which is invoked) ---
# Pinned (m9): unpinned @latest made image builds non-reproducible and could
# silently break the harness contract. 1.18.16 matches the installed CLI.
# After install, purge the npm cache (330MB of pure build-time waste) and drop
# the unused CPU-baseline opencode variant (176MB). The host CPU has AVX2/SSE4.2,
# so only the fast `opencode-linux-x64` binary ever loads.
RUN npm install -g opencode-ai@1.18.16 \
    && rm -rf /root/.npm \
    && rm -rf /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline

# --- Slim: docker daemon stack is never used inside the container ---
# The container talks to the HOST docker daemon through /var/run/docker.sock
# (mounted by Start-Autonomad.ps1) — it only needs the `docker` CLI, never
# dockerd/containerd/runc/shims. Remove the ~156MB daemon stack.
RUN rm -f /usr/sbin/dockerd /usr/bin/containerd /usr/sbin/runc \
        /usr/bin/containerd-shim /usr/bin/containerd-shim-runc-v1 /usr/bin/containerd-shim-runc-v2 \
    && rm -f /usr/bin/ctr /usr/bin/dnet

# --- Autonomad payload ---
WORKDIR $AUTONOMAD_HOME
COPY scripts/   ./scripts/
COPY adapters/  ./adapters/
COPY marketplace/ ./marketplace/
COPY src/       ./src/
COPY repo.config ./repo.config
COPY AGENTS.md  ./AGENTS.md
COPY pipeline-state.schema.json ./pipeline-state.schema.json

# marketplace/skills wiring target (see entrypoint): the dev sandbox mounts the
# AIOS brain under /brain and references .github/skills via skills.paths.
RUN mkdir -p /brain /data /workspace \
    && chmod +x scripts/*.sh adapters/*.sh

# Persistent runtime data: learning.db, reports/, runs.log, last_tick.ts
VOLUME ["/data"]

# gh auth is performed at container start from GH_TOKEN (see scripts/entrypoint.sh),
# then the pure-shell tick loop runs.
ENTRYPOINT ["/opt/autonomad/scripts/entrypoint.sh"]

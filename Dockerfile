# Dockerfile — isolated build/run of codebase-memory-mcp (cbm) for use as a
# containerized MCP server. See NEXT_STEPS.md for how to wire this into
# Claude Code.
#
# Rationale (from the security audit of this repo):
#   - Builds from source instead of downloading a release binary, so the
#     supply-chain trust boundary is "this exact git commit", not a
#     downloaded artifact.
#   - Static musl binary + minimal Alpine runtime -> small attack surface,
#     no dynamic deps to go stale.
#   - Runs as a non-root user with a read-only workspace mount by default.
#   - CBM_ALLOWED_ROOT is set explicitly (see audit finding: it is fail-open
#     when unset) and scoped to exactly the mounted project directory.
#
# Build:  docker build -t cbm:latest .
# Run:    see NEXT_STEPS.md

# ---- Build stage -----------------------------------------------------
# Same Alpine base/digest the project's own CI uses for portable static
# builds (test-infrastructure/Dockerfile.alpine) — pinned by digest, not a
# floating tag.
FROM alpine:3.21@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c AS builder

RUN apk add --no-cache \
    build-base \
    linux-headers \
    zlib-dev \
    zlib-static \
    bash \
    git \
    python3 \
    nodejs \
    npm \
    ca-certificates

WORKDIR /src
COPY . .

# --with-ui embeds the graph UI as a content-addressed sidecar (needs node,
# already installed above). STATIC=1 produces the fully static portable
# Linux binary so the runtime stage needs no libc/zlib at all.
RUN bash scripts/build.sh --with-ui CC=gcc CXX=g++ STATIC=1

# ---- Runtime stage -----------------------------------------------------
FROM alpine:3.21@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c

# git is required by the background watcher: it detects changes solely via
# `git rev-parse HEAD` / `git status --porcelain` (src/watcher/watcher.c).
# Without it the index never auto-syncs. safe.directory: on Linux hosts the
# bind-mounted project is owned by the host UID, not `cbm`, and git refuses it
# as "dubious ownership" (Docker Desktop on macOS remaps ownership, so it's a
# no-op there). Scope is fine: only /workspace is mounted.
RUN apk add --no-cache git \
    && git config --system --add safe.directory '*'

RUN addgroup -S cbm && adduser -S -G cbm -h /home/cbm -s /sbin/nologin cbm \
    && mkdir -p /workspace /home/cbm/.cache/codebase-memory-mcp \
    && chown -R cbm:cbm /home/cbm /workspace

COPY --from=builder /src/build/c/codebase-memory-mcp /usr/local/bin/codebase-memory-mcp

USER cbm
WORKDIR /workspace

# Fail-closed default: the audit found CBM_ALLOWED_ROOT is fail-open (broad
# denylist fallback) when unset. Pin it here to exactly the mount point so a
# malicious/crafted repo can't get the agent to index outside /workspace.
ENV CBM_ALLOWED_ROOT=/workspace
ENV CBM_CACHE_DIR=/home/cbm/.cache/codebase-memory-mcp

# No ENTRYPOINT/CMD on purpose: the persistent container is kept alive with
# `docker run ... cbm:latest sleep infinity` (see NEXT_STEPS.md), and each
# MCP session is launched separately via `docker exec -i <container>
# /usr/local/bin/codebase-memory-mcp`. An ENTRYPOINT here would get the
# placeholder command appended to it instead of replacing it, so the
# container would run the MCP binary as a one-shot CLI call and exit
# immediately instead of staying up.

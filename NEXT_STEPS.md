# Running codebase-memory-mcp (cbm) in Docker with Claude Code

This sets up `cbm` as a containerized MCP server so a compromised binary or a
malicious indexed repo is contained to the container instead of your host
account. Background and the security rationale are in the audit summary from
this conversation — the two things this setup specifically neutralizes are
(1) `CBM_ALLOWED_ROOT`'s fail-open default (there's nothing outside
`/workspace` for it to over-index into) and (2) a compromised binary having
your full user privileges.

## 0. One-time: pick a source commit, don't build off a moving branch

```bash
cd codebase-memory-mcp
git fetch --tags
git checkout <a-tag-or-commit-you-reviewed>   # not `main`
```

Rebuild the image whenever you intentionally update to a new reviewed commit.

## 1. Build the image

```bash
docker build -t cbm:latest .
```

This compiles from source (not a downloaded release binary) inside an Alpine
build stage, statically linked, then copies just the resulting binary into a
minimal runtime stage running as a non-root user. Takes a few minutes.

## 2. Create the cache volume and start a persistent container

The daemon this binary starts is meant to be a long-lived, shared background
process (per the project's own design — "one per-account coordination
daemon"). Keep one container running per project rather than spinning up a
fresh one per Claude Code session; `docker exec` attaches new MCP sessions to
the same daemon.

```bash
docker volume create cbm-cache

docker run -d \
  --name cbm-server \
  --init \
  --read-only \
  --tmpfs /tmp \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  -v "/absolute/path/to/your/project:/workspace/<project-folder>:ro" \
  -v cbm-cache:/home/cbm/.cache/codebase-memory-mcp \
  -e CBM_ALLOWED_ROOT=/workspace \
  -p 127.0.0.1:<project-port>:9749 \
  cbm:latest \
  sleep infinity
```

Notes on the flags:

- `-v "/absolute/path/to/your/project:/workspace:ro"` — **replace this path**
  with the actual project you want indexed. Mount only that one directory.
  Never mount `$HOME` or a parent of it — that mount is what actually scopes
  `CBM_ALLOWED_ROOT`, regardless of the env var.
- `:ro` — read-only is sufficient for indexing/querying. If some CLI-only
  feature you use needs to write into the project tree, drop `:ro`, but MCP
  tool usage doesn't need it.
- `-v cbm-cache:...` — a **named volume**, not a bind mount, so a cache-path
  bug can't reach an arbitrary host path.
- `-p 127.0.0.1:9749:9749` — publishes the graph UI to your host's loopback
  only. Never change this to `0.0.0.0:9749:9749` or drop the `127.0.0.1:`
  prefix — that would expose it to your local network. If you don't use the
  graph UI, drop this line and the container is unreachable from the network
  entirely (MCP still works over `docker exec`, which doesn't need a port).
- `--init`, `--cap-drop=ALL`, `--security-opt no-new-privileges`,
  `--read-only` + `--tmpfs /tmp` — standard container hardening; `--init`
  matters here specifically because the daemon detaches from its parent and
  needs a real init process to reap it correctly.
- `sleep infinity` — the container's own foreground process is just a
  placeholder to keep it alive; the actual MCP binary is launched per-session
  via `docker exec` in the next step, which is what starts the shared daemon
  on first use. (`tail -f /dev/null` looks equivalent but exits immediately
  under Alpine's busybox `tail` — verified this while testing the image, use
  `sleep infinity`.)

Check it started cleanly:

```bash
docker logs cbm-server
docker ps --filter name=cbm-server
```

## 3. Point Claude Code at the container

Add this to `~/.claude.json` (user scope) or your project's `.mcp.json`
(project scope) — same shape as the project's documented manual MCP config,
just wrapped in `docker exec`:

```json
{
  "mcpServers": {
    "codebase-memory-mcp": {
      "command": "docker",
      "args": ["exec", "-i", "-w", "/workspace/<project-folder>",
               "cbm-server", "/usr/local/bin/codebase-memory-mcp"]
    }
  }
}
```

<<<<<<< HEAD
=======
The `-w /workspace/<project-folder>` is required, not cosmetic: the server
derives the session's project root from its working directory. Without it,
`docker exec` starts in the image's `WORKDIR /workspace`, so the watcher is
registered on `/workspace` (not a git repo — nothing is ever auto-synced) and
the session's default project name doesn't match the indexed project.

>>>>>>> docker-watcher-fix
Do **not** use `cbm install` / the automatic installer for this setup — it
would write a `command` pointing at a host-side binary, which isn't what you
want here. This manual entry is the whole integration.

If you'd rather not hand-edit the config, `docker exec -i -w
/workspace/<project-folder> cbm-server /usr/local/bin/codebase-memory-mcp` is exactly what you'd otherwise get from
running the installer against a binary living on the host — you're just
substituting the container path for the host path.

## 4. Restart Claude Code and verify

Restart your Claude Code session, then run `/mcp`. You should see
`codebase-memory-mcp` listed with 15 tools, identical to a host install.

Try indexing:

```
> index this repository
```

and confirm the graph queries work. This path was tested directly (built the
image, started the container, and drove a real `initialize` → `tools/list`
JSON-RPC exchange through `docker exec -i` over a single held-open session):
both requests came back correctly and the container stayed up throughout, so
the MCP wiring above is confirmed working, not just plausible.

**Graph UI caveat (found during testing, not something to try to work
around):** the daemon that owns `localhost:9749` starts and tears itself back
down within each individual MCP request/response cycle (visible as
`daemon.start` / `daemon.runtime_stopping reason=last_committed_client_disconnected`
pairs in `${CBM_CACHE_DIR}/logs/cbm-daemon.log` inside the container — check
with `docker exec cbm-server cat /home/cbm/.cache/codebase-memory-mcp/logs/cbm-daemon.log`).
In testing, this meant the UI was not reliably reachable by just opening
`http://localhost:9749` in a browser — it's only "up" for the brief window of
an in-flight request, not for idle browsing. This wasn't something specific
to the Docker wrapping (the same `docker exec -i` session correctly served
two sequential MCP calls with a 6-second gap between them, so the underlying
tool-call functionality isn't affected) — it looks like how this build's
shared-daemon lifecycle behaves in general. If browsing the graph visually
matters to you, treat that as a secondary feature to validate independently
rather than assuming it works the same way the MCP tools do.

## 4b. Verifying Claude Code is actually using it, and keeping the index fresh

**Is Claude Code using the container?**

- `/mcp` in Claude Code lists `codebase-memory-mcp` as connected with 15 tools.
- `docker exec cbm-server ps` shows `codebase-memory-mcp` processes while a
  Claude session is open.
- Tail the daemon log; every session, watcher and index event lands here:
  ```bash
  docker exec cbm-server tail -f /home/cbm/.cache/codebase-memory-mcp/logs/cbm-daemon.log
  ```
  Look for `session.root.cwd path=/workspace/<project-folder>` (not bare
  `/workspace`) and `watcher.baseline ... strategy=git` (`strategy=none` means
  git is missing or the root is wrong).
- Ask Claude "list indexed projects" — it should answer via `list_projects`.
- Optional: add a line to the project's `CLAUDE.md` such as "Use the
  codebase-memory-mcp tools for code-structure questions before grep" so
  Claude reaches for it consistently.

**Does the `cbm-cache` index update by itself?** Partly:

- The background watcher polls `git status` / `HEAD` (every 5s + 1s per 500
  files, max 60s) and incrementally reindexes on change — but it lives in the
  shared daemon, which shuts down when the last MCP session disconnects. It
  only syncs **while a Claude Code session is open**.
- When a new session starts, the watcher adopts the current `HEAD` as its
  baseline. Commits made (or pulled) while no session was open are **not**
  picked up automatically; uncommitted edits are.
- So: start each session with "index this repository". It's incremental
  (only changed files are reparsed), so it's cheap, and it catches anything
  that changed offline. Alternatively enable auto-indexing on session start:
  ```bash
  docker exec cbm-server codebase-memory-mcp config set auto_index true
  ```
- Quick check the watcher can see the repo:
  ```bash
  docker exec cbm-server git -C /workspace/<project-folder> rev-parse HEAD
  ```

## 5. Day-to-day operation

- **Multiple projects**: run one container per project (`cbm-server-projA`,
  `cbm-server-projB`, ...), each with its own cache volume and its own
  `-v ...:/workspace:ro` mount, and a corresponding MCP entry per project's
  `.mcp.json`. Don't point two containers at the same cache volume.
- **Updating the tool**: pull/checkout the new commit, `docker build` again,
  then `docker rm -f cbm-server` and re-run the `docker run -d` command from
  step 2. The named `cbm-cache` volume persists across rebuilds, so the
  index isn't lost.
- **Stopping**: `docker stop cbm-server` when you're not actively using it;
  `docker start cbm-server` to bring it back (the cache volume and container
  config are preserved).
- **Removing everything**: `docker rm -f cbm-server && docker volume rm
  cbm-cache` to fully wipe it, including the index cache.

## 6. Keeping the codebase updated (fork + upstream sync)

This setup builds from source, so "updating" means pulling new upstream commits
into your own fork, rebuilding the image, and recreating the container. Keeping
your Docker files on a dedicated branch keeps `main` a pristine mirror of
upstream so updates fast-forward with no conflicts.

### 6a. One-time: fork and split remotes

Fork `DeusData/codebase-memory-mcp` to your own GitHub account (the "Fork"
button, or `gh repo fork DeusData/codebase-memory-mcp --clone=false`), then in
this clone:

```bash
git remote rename origin upstream                 # DeusData = read-only source
git remote add origin https://github.com/<your-username>/codebase-memory-mcp.git
git fetch origin
```

Move the Docker files (`Dockerfile`, `NEXT_STEPS.md`, `.dockerignore`) onto
their own branch so `main` never diverges from upstream:

```bash
git checkout -b with-docker
git add Dockerfile NEXT_STEPS.md .dockerignore
git commit -m "Add Docker setup for containerized MCP server"
git push -u origin with-docker
```

### 6b. Each time you want the latest upstream changes

```bash
# 1. Fast-forward main to upstream (never diverges, so this always works)
git checkout main
git pull --ff-only upstream main
git push origin main                              # optional: update your fork

# 2. Replay your Docker commit onto the new main
git checkout with-docker
git rebase main
git push --force-with-lease origin with-docker
```

Because the Docker files are just added files upstream never touches, the
rebase applies cleanly in almost all cases. If `scripts/build.sh`, the Alpine
base image, or the build inputs changed, re-check this file's steps 0–2 before
rebuilding.

### 6c. Pin to a reviewed commit, then rebuild

Per step 0, don't build off a moving branch. After rebasing, tag the exact
commit you reviewed and build from the tag:

```bash
git tag cbm-review-$(date +%Y%m%d)
git push origin --tags

git checkout cbm-review-<date>                    # detached HEAD on the reviewed commit
docker build -t cbm:latest .
```

### 6d. Swap the running container onto the new image

The `cbm-cache` named volume persists across rebuilds, so the index is **not**
lost — the container just re-attaches to the existing cache.

```bash
docker rm -f cbm-server
# re-run the `docker run -d ...` command from step 2 verbatim
docker logs cbm-server
```

Then restart your Claude Code session and re-run `/mcp` to confirm the tools
still load (step 4). If the daemon reports an exact-build admission conflict in
`cbm-daemon.log`, make sure no host-installed `codebase-memory-mcp` binary or
another `cbm-server*` container from an older image is still running against
the same cache root.

## What this setup does *not* protect against

- A compromised binary still has full access to whatever's mounted into
  `/workspace` (that's unavoidable — it needs to read your code) and to the
  `cbm-cache` volume. It does **not** have access to the rest of your
  filesystem, your host's `~/.claude`/`~/.cursor`/etc. config files, your SSH
  keys, or other projects — that's the actual isolation gained.
- This does not sandbox *your own* review of the code — it only limits what
  a malicious binary or a malicious indexed repo could reach if one turned
  out to be hostile.

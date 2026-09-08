# Hermes Assistant — Option C (isolated whole-process Docker)

Whole-process Hermes in Podman/Docker. Host `~/.bashrc`, OpenClaw, and SSH keys are not mounted.

## Credentials (no `.env` files)

Keys stay in **your shell** (e.g. from `~/.bashrc`). The wrapper forwards only names listed in `~/.hermes-assistant/env.allowlist` into the container at start time. **No values are stored on disk.**

```bash
nano ~/.hermes-assistant/env.allowlist   # variable NAMES only
source ~/.bashrc                         # or however you load keys
hermes-assistant-wrapper.sh start
```

From **bucephalus3** (hermes user, keys in your shell):

```bash
source ~/.bashrc
~/hermes-assistant/scripts/launch-with-host-env.sh start
```

Optional: `config.yaml` → `terminal.env_passthrough` for tool subprocesses (subset of allowlist; not provider keys).

## Layout

| Path | Purpose |
|------|---------|
| `~/hermes-assistant/` | Compose, scripts, systemd unit |
| `~/.hermes-assistant/` | Hermes state (`HERMES_HOME` → `/opt/data`) |
| `~/.hermes-assistant/env.allowlist` | Names to forward from your shell (no values) |
| `~/hermes-workspace/` | Git projects (`/opt/data/workspace` in container) |
| `~/bin/hermes-assistant` | Host CLI (`podman exec … hermes`) |

`~/.hermes-assistant` and `~/hermes-workspace` are **host bind mounts** (same pattern as a typical Hermes container: `~/.hermes:/opt/data`). Rebuild / `recreate` replaces only the image and container; sessions, memories, `SOUL.md`, skills, and workspace files reload from those dirs. Do not run `compose down -v`.

The wrapper writes `~/hermes-assistant/.env` for compose interpolation (quoted absolute mount paths and UIDs only — no API keys). That is not the optional secrets file at `~/.hermes-assistant/.env`. podman-compose uses `.env` only for **unset** variables; an empty `HERMES_DATA_DIR=` in the shell still wins. The wrapper unsets empty mount vars before compose.

Optional recreate smoke (marker lives on the bind, so it must still be there after rebuild):

```bash
podman exec --user hermes hermes-assistant sh -c 'echo persist-ok > /opt/data/.persist-smoke'
~/hermes-assistant/scripts/hermes-assistant-wrapper.sh recreate
podman exec --user hermes hermes-assistant grep persist-ok /opt/data/.persist-smoke
```

## First-time setup

```bash
cd ~/hermes-assistant
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

## Daily use

```bash
source ~/.bashrc   # load keys into shell first
hermes-assistant-wrapper.sh start
hermes-assistant chat
hermes-assistant-wrapper.sh status
# Dashboard: http://127.0.0.1:9120
```

## systemd

Two layouts, two units:

- **Direct operator** (`bucephalus3` runs the container): `hermes-assistant-gateway.service` via `install-systemd-user.sh`.
- **Dedicated `hermes` user**: `hermes-assistant.service` via `install-autostart.sh`. That path installs `/usr/local/sbin/hermes-assistant-privileged.sh` (root:root) and a narrow NOPASSWD sudoers rule pointing at it — not at a user-writable `scripts/` copy.

Direct operator:

```bash
bash ~/hermes-assistant/scripts/install-systemd-user.sh
systemctl --user enable --now hermes-assistant-gateway.service
systemctl --user restart hermes-assistant-gateway.service
journalctl --user -u hermes-assistant-gateway.service -f
```

Rebuild the image after upstream changes (slow; not via systemd). Host binds are reused:

```bash
~/hermes-assistant/scripts/hermes-assistant-wrapper.sh recreate
```

There is **no** `hermes_agent.service`. The old name was wrong.

## Verify isolation

```bash
~/hermes-assistant/scripts/verify-isolation.sh
```

## Pinned Hermes Agent version

This kit does not vendor Python/Node packages. The container is built from a **pinned** [hermes-agent](https://github.com/nousresearch/hermes-agent) commit in [`hermes-agent.lock`](hermes-agent.lock). That commit's `uv.lock` and `package-lock.json` freeze downloadable libraries (`uv sync --frozen` in the Dockerfile). `.venv/` and `node_modules/` are gitignored and excluded from the build-context rsync.

`prepare-build-context.sh` and `hermes-assistant-wrapper.sh recreate` refuse to build if the checkout (or `.hermes-agent-commit` stamp) does not match the lock. Bypass: `HERMES_SKIP_UPSTREAM_PIN=1`.

Refresh the pin after `git pull` in `~/0_Development/hermes-agent`:

```bash
~/hermes-assistant/scripts/update-hermes-agent-pin.sh
sudo bash ~/hermes-assistant/scripts/prepare-build-context.sh
source ~/.bashrc
~/hermes-assistant/scripts/hermes-assistant-wrapper.sh recreate
```

## Rebuild after upstream updates

```bash
sudo bash ~/hermes-assistant/scripts/prepare-build-context.sh
source ~/.bashrc
hermes-assistant-wrapper.sh recreate
```

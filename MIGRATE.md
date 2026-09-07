# Migrate Hermes to dedicated user `hermes`

> **Rebuild doc:** keep `/home/bucephalus3/0_Development/arch-blueprints/hermes-isolated-assistant/README.md` updated whenever this kit changes.

This moves Hermes off `bucephalus3` into `/home/hermes/` with correct UID
mapping (`HERMES_UID` = hermes's uid, not yours).

## Autostart (systemd)

systemd has no interactive shell, so API keys come from
`~/hermes-assistant/config/env.secrets` (mode 600, gitignored).

```bash
# 1. Put keys in your shell (or edit env.secrets after install)
source ~/.bashrc

# 2. One-time install (sudoers + linger + user unit)
sudo bash /home/bucephalus3/hermes-assistant/scripts/install-autostart.sh

# 3. Daily ops
systemctl --user status hermes-assistant.service
systemctl --user restart hermes-assistant.service
journalctl --user -u hermes-assistant.service -f
```

After reboot the operator user unit starts `launch-with-host-env.sh` →
`run-as-hermes-privileged.sh` (passwordless sudo) → hermes wrapper.

Update secrets: edit `config/env.secrets`, then `systemctl --user restart hermes-assistant.service`.

## Admin access (root / sudo)

`/home/hermes` is mode **755** so **root can list and manage** the tree:

```bash
sudo ls /home/hermes
sudo ls -la /home/hermes/.hermes-assistant
sudo nano /home/hermes/.hermes-assistant/env.allowlist
sudo -u hermes bash -lc 'hermes-assistant-wrapper.sh status'
```

**Without `sudo`**, as `bucephalus3`, you may see directory names under `/home/hermes` (755) but **cannot read** `.hermes-assistant` (700).

If migrate used old `chmod 750` and `sudo ls /home/hermes` fails oddly, fix permissions
(**always the kit path** — never `sudo bash /home/hermes/.../fix-home-permissions.sh`):

```bash
sudo bash /home/bucephalus3/hermes-assistant/scripts/fix-home-permissions.sh
```

That script refuses to run from `/home/hermes/...` (hermes-writable after migrate).
It also sets `hermes-workspace` to **750**, hardens secret file modes, and installs
admin scripts under the deployed tree as **root:root 0755**.

## Sync updated kit to deployed tree

Prefer the sync helper (installs admin scripts as root:root):

```bash
sudo bash /home/bucephalus3/hermes-assistant/scripts/sync-to-hermes.sh
sudo bash /home/bucephalus3/hermes-assistant/scripts/fix-home-permissions.sh
```

Or manually:

```bash
sudo bash /home/bucephalus3/hermes-assistant/scripts/sync-to-hermes.sh
# Do NOT chown -R hermes on scripts/ after sync — that undoes root:root admin scripts.
sudo bash /home/bucephalus3/hermes-assistant/scripts/fix-home-permissions.sh
```

Resume bootstrap (if needed):

```bash
sudo bash ~/hermes-assistant/scripts/prepare-build-context.sh
sudo -u hermes bash -lc 'cd ~/hermes-assistant && ./scripts/resume-bootstrap.sh'
```

Full migrate (first time or re-run):

```bash
sudo bash ~/hermes-assistant/scripts/migrate-to-hermes-user.sh
```

Log: `/tmp/hermes-migrate-*.log`

## What the script does

1. Creates Linux user `hermes` (no sudo for that user)
2. Stops any `hermes-assistant` containers under bucephalus3
3. Copies to `/home/hermes/`: `hermes-assistant/`, `.hermes-assistant/`, `hermes-workspace/`
4. Sets `chmod 755` on `/home/hermes`, `700` on `.hermes-assistant`
5. Enables rootless Podman linger for `hermes`
6. Runs `bootstrap.sh` as hermes
7. Disables bucephalus3 systemd unit; replaces `~/bin/hermes-assistant*` with redirect messages
8. Renames old dirs under bucephalus3 to `*.migrated-<timestamp>`

## After migration — daily use

```bash
source ~/.bashrc
~/hermes-assistant/scripts/launch-with-host-env.sh start
~/hermes-assistant/scripts/launch-with-host-env.sh status
# chat (as hermes): sudo -u hermes bash -lc 'hermes-assistant chat'
```

Or interact as hermes if that shell has keys:

```bash
su - hermes -c 'hermes-assistant chat'
```

## systemd

Autostart **does not** inherit your interactive shell keys. Prefer `launch-with-host-env.sh` from your session.

## Verify separation

As **bucephalus3 without sudo**:

```bash
cat /home/hermes/.hermes-assistant/env.allowlist   # Permission denied
hermes-assistant chat                              # redirect message
```

## Build context note

Rootless Podman builds as `hermes` — sync upstream into `/home/hermes/hermes-agent`:

```bash
sudo bash /home/hermes/hermes-assistant/scripts/prepare-build-context.sh
```

## Rootless Podman note

```bash
sudo podman ps                    # often empty — wrong store
sudo -u hermes podman ps          # correct
```

## Security: harden bucephalus3 against host user `hermes`

Full audit (P1–P4): `/home/bucephalus3/0_Development/arch-blueprints/hermes-isolated-assistant/README.md` §8.

Containers do **not** mount your home, but host user `hermes` can read world-readable files (e.g. `644` `.bashrc`). These chmods only change **on-disk** permissions — they do not break already-running shells.

**Forward (apply):**

```bash
ls -ld /home/bucephalus3
ls -l /home/bucephalus3/.bashrc /home/bucephalus3/.openclaw /home/bucephalus3/.ssh 2>/dev/null

chmod 750 /home/bucephalus3
chmod 700 /home/bucephalus3/.openclaw
chmod 700 /home/bucephalus3/.ssh
chmod 600 /home/bucephalus3/.bashrc
# optional split: chmod 644 ~/.bashrc && chmod 600 ~/.bashrc.secrets

sudo -u hermes test -r /home/bucephalus3/.bashrc && echo LEAK || echo OK
sudo -u hermes test -r /home/bucephalus3/.openclaw/openclaw.json && echo LEAK || echo OK
```

**Rollback (if something breaks):**

```bash
chmod 755 /home/bucephalus3
chmod 644 /home/bucephalus3/.bashrc
chmod 644 /home/bucephalus3/.bashrc.secrets 2>/dev/null || true
chmod 755 /home/bucephalus3/.openclaw
chmod 700 /home/bucephalus3/.ssh
chmod 600 /home/bucephalus3/.ssh/* 2>/dev/null || true
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Permission denied on `compose.runtime.yml` | Sync scripts; runtime file now lives in `hermes-assistant/` not `.hermes-assistant/`; run `sudo bash /home/bucephalus3/hermes-assistant/scripts/fix-home-permissions.sh` |
| Could not read env.allowlist | Edit **`~/hermes-assistant/config/env.allowlist`** (not under mode-700 `.hermes-assistant`) |
| Volume paths like `.../.hermes-assistant}` | podman-compose nested `${VAR:-${HOME}/...}` bug — sync fixed `docker-compose.yml`, then `launch-with-host-env.sh recreate` |
| `cannot chdir to /home/bucephalus3/...: Permission denied` during remapping | Operator cwd was unreadable to hermes; re-run `sudo bash /home/bucephalus3/hermes-assistant/scripts/fix-home-permissions.sh` (kit now cds to `/home/hermes` before `podman unshare`) |
| Dashboard blank / connection refused on `:9119` | Dashboard is **inside** `hermes-assistant` (s6), not a second container. Run `~/hermes-assistant/scripts/check-dashboard.sh`; confirm `HERMES_DASHBOARD=1` in `podman exec hermes-assistant env`; check `podman logs hermes-assistant` for dashboard crash; restart with `launch-with-host-env.sh restart` |
| Pulling `hermes-assistant_dashboard:latest` / access denied | Stale `compose.runtime.yml` still has ghost `dashboard:` service. Sync kit + recreate: `sudo bash …/sync-to-hermes.sh` then `launch-with-host-env.sh recreate` |
| `grep: /opt/data/config.yaml: Permission denied` in verify | File is `root:root 0600` (often from volume `:U`). Kit compose no longer uses `:U`; sync + recreate. Immediate repair: `sudo -u hermes bash -lc 'podman exec -u root hermes-assistant chown hermes:hermes /opt/data/config.yaml; podman exec -u root hermes-assistant chmod 640 /opt/data/config.yaml'` |
| `XDG_RUNTIME_DIR ... is not owned by the current user` | Do not use `sudo -E`; use updated `launch-with-host-env.sh` |
| `container-runtime.sh: No such file or directory` | Re-install wrappers to `/home/hermes/bin/` |
| `sudo podman ps` empty | Use `sudo -u hermes podman ps` |
| `Dockerfile not found` | Run `prepare-build-context.sh`, then `resume-bootstrap.sh` |

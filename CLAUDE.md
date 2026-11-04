# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Ops scripts for the `home2.xyztem.dev` host, checked out there at `/home/idertator/services`: a nightly backup job for TopGroup production infrastructure, its crontab, and the installer for the t3-logs agent. Plain bash, no build system, no tests, no linter config.

- `backup/` — `t3backup.sh` (the backup job) and a `Makefile` to install it.
- `cron/crontab.txt` — crontab that runs the backup nightly at 23:00 and appends output to `~/crontab.log`.
- `logs/setup-agent.sh` — downloads the t3-logs agent installer from the private `topgroupx/t3-logs` repo (tag `agent/v${T3LOGS_VERSION}`) and runs it with sudo. Reads `GH_TOKEN` from the environment or from `logs/.env`.

## Commands

On the server, from the repo root (needs `backup/.env` and `logs/.env` in place):

```bash
make install         # install-deps + check + backup + crontab + agent, in that order
make install-deps    # Debian 13 only, sudo: apt packages + postgresql-client-18 from PGDG
make check           # verify required commands and both .env files exist
make backup          # backup/ install: symlink, `prod` MinIO alias
make crontab         # REPLACES the user's crontab with cron/crontab.txt (old one saved to ~/crontab.<ts>.bak)
make agent           # runs logs/setup-agent.sh (uses sudo)
make -n install      # dry run
bash -n backup/t3backup.sh  # syntax check (no test suite exists)
```

Sub-Makefiles run through `make -C`, so use `$(CURDIR)`, not `${PWD}`, for paths inside them.

Running `t3backup.sh` performs real backups against production hosts and reports to t3-logs; there is no dry-run mode. To exercise a unit without reporting, pass `"nop"` as its token.

Runtime deps: `curl`, `jq`, `uuidgen` (checked at startup), plus `pg_dump`, `rsync`, `git`, and the MinIO client. The client is `mc` on macOS and `minio-client` on Linux (the Debian `minio-client` package, installed by `make install-deps`; `mc` there is Midnight Commander); the script picks by `uname`.

## t3backup.sh architecture

The script is a library of functions followed by a "Run" section at the bottom. **Each backup unit is one function call in that section**, taking a target name and that unit's own t3-logs ingestion JWT. Adding, removing or disabling a unit means editing only those lines.

Unit types: `t3b_postgres_db` (`pg_dump -Fc` to `postgres/YYYYMMDD_<db>`, then `t3b_postgres_prune` deletes dumps older than `POSTGRES_RETENTION_DAYS`), `t3b_minio_bucket` (`mirror prod/<bucket>` into one dir per bucket so each is measured separately), and `t3b_git_repo` (clone or fetch+pull under `git/`, inside a subshell so a failed `cd` doesn't leak).

Every unit follows the same pattern: generate `event_id` + `started_at` before work, capture stderr to a temp file, then call `t3b_report` with `succeeded` (artifact path, item count, byte size) or `failed` (last 2000 bytes of stderr).

`t3b_report` invariants (contract defined in the t3-logs repo, `docs/backup-integration.md`):
- `event_id` is created once per run and reused across retries — this is what makes ingestion idempotent. Don't regenerate it inside the retry loop.
- Timestamps are RFC 3339 with the real Europe/Madrid offset (`t3b_madrid_now`); t3-logs rejects others.
- The bearer token is written to a 0600 curl config file, never passed on the command line (visible in `ps`).
- Retries with exponential backoff (5s, up to 6 attempts) only on 408/429/5xx/network errors; other codes are logged and dropped.
- Reporting failures never affect the exit code. `T3B_EXIT_CODE` is set to 1 only by failed backups.

Keep the script portable between GNU (Linux server) and BSD (macOS) userland — use or extend the `t3b_*` portability helpers (`date`, `stat`, `du`) rather than calling GNU-only flags directly.

Bump `T3_BACKUP_VERSION` when changing the script.

## Secrets

Secrets live in a `.env` next to each script that needs them: `backup/.env` and `logs/.env` (`GH_TOKEN`). Both are gitignored and mode 0600. The rest of this section is about `backup/.env`. `.env.example` is the tracked list of every required variable. Keep the two in sync. The file is plain `KEY=value` with no quotes, because both bash (`set -a; . .env`) and make (`-include .env`) read it.

- The script finds `.env` next to its real path, resolving the `~/.local/bin` symlink. `T3_BACKUP_ENV` overrides that location.
- t3-logs tokens are named `T3LOGS_TOKEN_<PG|MINIO|GIT>_<NAME>`. Adding a unit means adding its variable to both env files.
- `"nop"` is the only explicit opt-out from reporting. An empty token means the variable is missing; the script logs a warning and still runs the backup.

Never write secret values into tracked files.

## Gotchas

- `T3_BACKUP_PATH` is hardcoded in the script, so the value set in `crontab.txt` is overridden.
- The crontab invokes `/home/idertator/services/backup/t3backup.sh` directly, not the `~/.local/bin/t3backup` symlink that `make install` creates.

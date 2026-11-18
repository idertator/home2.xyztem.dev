# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Ops scripts for the `home2.xyztem.dev` host, checked out there at `/home/idertator/services`: a nightly backup job for TopGroup production infrastructure and its crontab. Plain bash, no build system, no tests, no linter config.

- `backup/` — `t3backup.sh` (the backup job) and a `Makefile` to install it.
- `cron/crontab.txt` — crontab that runs the backup nightly at 23:00 and appends output to `~/crontab.log`.

## Commands

On the server, from the repo root (needs `backup/.env` in place):

```bash
make install         # install-deps + check + backup + crontab, in that order
make install-deps    # Debian 13 only, sudo: apt packages + postgresql-client-18 from PGDG
make check           # verify required commands and backup/.env exist
make backup          # backup/ install: symlink, `prod` MinIO alias
make crontab         # REPLACES the user's crontab with cron/crontab.txt (old one saved to ~/crontab.<ts>.bak)
make -n install      # dry run
bash -n backup/t3backup.sh  # syntax check (no test suite exists)
```

Sub-Makefiles run through `make -C`, so use `$(CURDIR)`, not `${PWD}`, for paths inside them.

Running `t3backup.sh` performs real backups against production hosts; there is no dry-run mode.

Runtime deps: `pg_dump`, `rsync`, `git`, and the MinIO client. The client is `mc` on macOS and `minio-client` on Linux (the Debian `minio-client` package, installed by `make install-deps`; `mc` there is Midnight Commander); the script picks by `uname`.

## t3backup.sh architecture

The script is a library of functions followed by a "Run" section at the bottom. **Each backup unit is one function call in that section**, taking a target name. Adding, removing or disabling a unit means editing only those lines.

Unit types: `t3b_postgres_db` (`pg_dump -Fc` to `postgres/YYYYMMDD_<db>`, then `t3b_postgres_prune` deletes dumps older than `POSTGRES_RETENTION_DAYS`), `t3b_minio_bucket` (`mirror prod/<bucket>` into one dir per bucket), and `t3b_git_repo` (clone or fetch+pull under `git/`, inside a subshell so a failed `cd` doesn't leak).

Units write their own output and errors straight to stdout/stderr (the crontab appends both to `~/crontab.log`). A failing unit sets `T3B_EXIT_CODE=1` and the run continues with the next one.

Keep the script portable between GNU (Linux server) and BSD (macOS) userland — avoid GNU-only flags (`date`, `stat`, `du`, `sed -i`).

Bump `T3_BACKUP_VERSION` when changing the script.

## Secrets

Secrets live in `backup/.env` (`MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY`, read by `backup/Makefile` via `-include .env` to set up the `prod` MinIO alias). It is gitignored and mode 0600. `backup/.env.example` is the tracked list of required variables; keep the two in sync. Plain `KEY=value`, no quotes. `t3backup.sh` itself reads no secrets.

Never write secret values into tracked files.

## Gotchas

- `T3_BACKUP_PATH` is hardcoded in the script, so the value set in `crontab.txt` is overridden.
- The crontab invokes `/home/idertator/services/backup/t3backup.sh` directly, not the `~/.local/bin/t3backup` symlink that `make install` creates.

# Replica member of the `xyztem` Patroni cluster; see docker-compose.yml.
# Run from this directory.

IMAGE := xyztem/postgres:18-patroni
# Bind-mounted as /var/lib/postgresql; see docker-compose.yml.
DATA_DIR := /srv/postgresql
# The image's postgres user (official postgres images use 999).
PG_UID := 999

.PHONY: up down etcd status data-dir

# The image is not built here: run `make build ship HOST=<this server>` from
# home3.xyztem.dev/postgresql on idertator-server-03 first. On an empty
# volume Patroni clones the primary with pg_basebackup (~85 GB) before the
# member shows up as a running replica in `make status`.
up:
	@docker image inspect $(IMAGE) >/dev/null 2>&1 || { echo "$(IMAGE) is missing: ship it from idertator-server-03 (make ship HOST=...)" >&2; exit 1; }
	@[ "$$(stat -c %u $(DATA_DIR) 2>/dev/null)" = $(PG_UID) ] || { echo "$(DATA_DIR) is missing or not owned by uid $(PG_UID): run make data-dir" >&2; exit 1; }
	docker compose up -d

# Create the data directory for the bind mount. Uses sudo; run once.
data-dir:
	sudo install -d -o $(PG_UID) -g $(PG_UID) -m 0700 $(DATA_DIR)

down:
	docker compose down

# Start only this node's etcd member. Run on all three servers before the
# first Patroni start: Patroni needs etcd quorum (two members) to elect a leader.
etcd:
	docker compose up -d etcd

# Members, roles, lag.
status:
	docker compose exec postgres patronictl -c /etc/patroni list

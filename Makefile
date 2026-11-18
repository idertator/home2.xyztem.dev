# Install everything on home2.xyztem.dev (checked out at /home/idertator/services).
#
#   make install   install system packages, check prerequisites, then install
#                  backup and crontab
#   make check     only check prerequisites
#
# Individual steps: make backup | make crontab
# System packages only (Debian 13, uses sudo): make install-deps

BACKUP_DEPS := pg_dump rsync git minio-client

# pg_dump must be at least as new as the server, and Debian 13 only ships
# PostgreSQL 17, so the client comes from the PGDG apt repository.
PG_VERSION := 18
PGDG_KEY := /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
DEBIAN_PKGS := ca-certificates curl rsync git minio-client postgresql-client-$(PG_VERSION)

.PHONY: install install-deps check backup crontab

install: install-deps check backup crontab

# Debian 13 only; uses sudo, so it may prompt for a password.
install-deps:
	@. /etc/os-release; \
	if [ "$$ID" != debian ] || [ "$$VERSION_ID" != 13 ]; then \
		echo "install-deps supports Debian 13 only (found $$PRETTY_NAME)"; exit 1; \
	fi
	sudo apt-get update
	sudo apt-get install -y ca-certificates curl
	sudo install -d /usr/share/postgresql-common/pgdg
	sudo curl -fsSL -o $(PGDG_KEY) https://www.postgresql.org/media/keys/ACCC4CF8.asc
	@. /etc/os-release; \
	echo "deb [signed-by=$(PGDG_KEY)] https://apt.postgresql.org/pub/repos/apt $$VERSION_CODENAME-pgdg main" \
		| sudo tee /etc/apt/sources.list.d/pgdg.list
	sudo apt-get update
	sudo apt-get install -y $(DEBIAN_PKGS)
	pg_dump --version

check:
	@missing=""; \
	for cmd in $(BACKUP_DEPS); do \
		command -v $$cmd >/dev/null 2>&1 || missing="$$missing $$cmd"; \
	done; \
	if [ -n "$$missing" ]; then echo "Missing commands:$$missing"; exit 1; fi
	@if [ ! -f backup/.env ]; then echo "Missing backup/.env: copy backup/.env.example and fill it in"; exit 1; fi
	@echo "Prerequisites OK"

backup:
	$(MAKE) -C backup install

# Replaces the user's whole crontab with cron/crontab.txt; the previous one is
# saved next to it first so it can be restored with `crontab <file>`.
crontab:
	@backup_file=$(HOME)/crontab.$$(date +%Y%m%d%H%M%S).bak; \
	if crontab -l > $$backup_file 2>/dev/null; then \
		echo "Previous crontab saved to $$backup_file"; \
	else \
		rm -f $$backup_file; \
	fi
	crontab $(CURDIR)/cron/crontab.txt
	@echo "Crontab installed:"; crontab -l

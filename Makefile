# Install everything on home2.xyztem.dev (checked out at /home/idertator/services).
#
#   make install   check prerequisites, then install backup, crontab and t3-logs agent
#   make check     only check prerequisites
#
# Individual steps: make backup | make crontab | make agent

BACKUP_DEPS := curl jq uuidgen pg_dump rsync git

.PHONY: install check backup crontab agent

install: check backup crontab agent

check:
	@missing=""; \
	for cmd in $(BACKUP_DEPS); do \
		command -v $$cmd >/dev/null 2>&1 || missing="$$missing $$cmd"; \
	done; \
	if [ -n "$$missing" ]; then echo "Missing commands:$$missing"; exit 1; fi
	@for f in backup/.env logs/.env; do \
		if [ ! -f $$f ]; then echo "Missing $$f: copy $$f.example and fill it in"; exit 1; fi; \
	done
	@echo "Prerequisites OK"

backup:
	@if [ ! -x $(HOME)/.local/bin/mcc ]; then $(MAKE) -C backup install-minio; fi
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

# setup-agent.sh downloads install.sh into the working directory and runs it
# with sudo, so it may prompt for a password.
agent:
	chmod 600 logs/.env
	cd logs && bash ./setup-agent.sh

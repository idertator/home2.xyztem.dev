# Secrets: plain KEY=value file, untracked (see .env.example).
-include .env

install:
	@if [ ! -f .env ]; then echo "Missing .env: cp .env.example .env and fill it in"; exit 1; fi
	chmod 600 .env

	@echo "Create bin directory if it doesn't exist"
	if [ ! -d ${HOME}/.local/bin ]; then mkdir -p ${HOME}/.local/bin; fi

	@echo "Check if link already exists"
	if [ -L ${HOME}/.local/bin/t3backup ]; then rm ${HOME}/.local/bin/t3backup; fi

	@echo "Create symlink"
	ln -s $(CURDIR)/t3backup.sh ${HOME}/.local/bin/t3backup
	
	@echo "Setup minio"
	@if [ -z "$(MINIO_ACCESS_KEY)" ] || [ -z "$(MINIO_SECRET_KEY)" ]; then echo "MINIO_ACCESS_KEY / MINIO_SECRET_KEY missing from .env"; exit 1; fi
	@mcc alias set prod https://minio.topgroupexpress.com $(MINIO_ACCESS_KEY) $(MINIO_SECRET_KEY)

install-minio:
	curl https://dl.min.io/client/mc/release/linux-amd64/mc --create-dirs -o ${HOME}/.local/bin/mcc
	chmod +x ${HOME}/.local/bin/mcc

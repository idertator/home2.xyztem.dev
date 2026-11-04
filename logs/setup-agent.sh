#!/bin/bash

T3LOGS_VERSION="1.2.0"

# Secrets live in .env next to this script (untracked; see .env.example).
# A GH_TOKEN already in the environment wins over the file.
ENV_FILE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [ -z "${GH_TOKEN}" ] && [ -r "${ENV_FILE}" ]; then
  set -a
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  set +a
fi

if [ -z "${GH_TOKEN}" ]; then
  echo "GH_TOKEN is not set (export it or put it in ${ENV_FILE})" >&2
  exit 1
fi

curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github.raw" \
  -o install.sh \
  "https://api.github.com/repos/topgroupx/t3-logs/contents/deploy/agent/install.sh?ref=agent/v${T3LOGS_VERSION}" \
  || { echo "Failed to download install.sh (check GH_TOKEN is valid and can read topgroupx/t3-logs)" >&2; exit 1; }

sudo GH_TOKEN="${GH_TOKEN}" bash install.sh v${T3LOGS_VERSION}
status=$?

rm -f install.sh
exit $status

#!/bin/bash
#
# T3 Backup
#
# Every backup unit is a single call at the bottom of this file, taking the
# unit's name and its own t3-logs ingestion token. Comment a line out to skip
# that unit; nothing else needs to change. Pass "nop" as the token to run a
# backup without reporting it.
#
# Secrets (the tokens and MEILI_API_KEY) live in .env next to this script,
# which is untracked; .env.example lists every variable it must define.
# T3_BACKUP_ENV overrides its location.
#
# Each unit reports its outcome to t3-logs (see the t3-logs repo,
# docs/backup-integration.md). A reporting failure never masks a backup
# failure: the exit code reflects the backups only.

T3_BACKUP_VERSION="1.4.0"
T3_BACKUP_PATH="/srv/backup"

T3LOGS_URL="https://logs.topgroupexpress.com"
T3LOGS_ENDPOINT="${T3LOGS_URL}/v1/ingest/backup-results"

POSTGRES_HOST="37.187.250.111"
POSTGRES_PORT="5432"
POSTGRES_USER="postgres"
POSTGRES_RETENTION_DAYS="10"

MINIO_HOST="37.187.250.111"

MEILI_URL="https://meili.topgroupexpress.com"
MEILI_SNAPSHOT_HOST="ubuntu@37.187.250.111"
MEILI_SNAPSHOT_PATH="/home/ubuntu/repos/server-production-3/meili/data/snapshots"

# Set to 1 by any failing backup unit; returned as the script's exit code.
T3B_EXIT_CODE=0

error_message() {
  echo $'\e[31m'"$1"$'\e[0m'
}

# Resolve the real script directory: make install runs it through a symlink
# in ~/.local/bin, and the .env sits beside the real file.
t3b_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir=$(cd -P "$(dirname "$src")" && pwd)
        src=$(readlink "$src")
        case "$src" in /*) ;; *) src="${dir}/${src}" ;; esac
    done
    cd -P "$(dirname "$src")" && pwd
}

T3_BACKUP_ENV="${T3_BACKUP_ENV:-$(t3b_script_dir)/.env}"
if [ ! -r "${T3_BACKUP_ENV}" ]; then
    error_message "Secrets file not readable: ${T3_BACKUP_ENV} (copy .env.example and fill it in)"
    exit 1
fi
set -a
# shellcheck source=/dev/null
. "${T3_BACKUP_ENV}"
set +a

os=$(uname)
if [ "$os" = "Darwin" ]; then
    MINIO_CLIENT="mc"
elif [ "$os" = "Linux" ]; then
    MINIO_CLIENT="mcc"
else
    error_message "Unsupported operating system: $os"
    exit 1
fi

# ---------------------------------------------------------------------------
# Portability helpers (GNU coreutils on Linux, BSD userland on macOS)
# ---------------------------------------------------------------------------

# RFC 3339 with the Europe/Madrid offset t3-logs enforces. The offset must be
# the real one at that instant (+02:00 in summer, +01:00 in winter), so it is
# read from date rather than hardcoded.
t3b_madrid_now() {
    if [ "$os" = "Darwin" ]; then
        TZ=Europe/Madrid date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/'
    else
        TZ=Europe/Madrid date +%Y-%m-%dT%H:%M:%S%:z
    fi
}

t3b_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

t3b_file_size() {
    if [ "$os" = "Darwin" ]; then
        stat -f %z "$1" 2>/dev/null || echo 0
    else
        stat -c %s "$1" 2>/dev/null || echo 0
    fi
}

# du -sb is GNU-only; kilobytes are portable and precise enough for a report.
t3b_dir_size() {
    local kb
    kb=$(du -sk "$1" 2>/dev/null | cut -f1)
    echo $(( ${kb:-0} * 1024 ))
}

t3b_dir_count() {
    find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

t3b_error_text() {
    local log="$1" fallback="$2" text
    text=$(tail -c 2000 "$log" 2>/dev/null)
    [ -n "$text" ] || text="$fallback"
    printf '%s' "$text"
}

# ---------------------------------------------------------------------------
# t3-logs reporting
# ---------------------------------------------------------------------------

# t3b_report <token> <event_id> <started_at> <status> <artifact> <items> <bytes> <error>
#
# The event_id is generated before the backup runs and reused across retries,
# which is what makes reporting idempotent: a response lost on the wire cannot
# produce two rows for one run.
t3b_report() {
    local token="$1" event_id="$2" started_at="$3" status="$4"
    local artifact="$5" item_count="$6" size_bytes="$7" error="$8"

    if [ "$token" = "nop" ]; then
        return 0
    fi

    # An empty token is a variable missing from .env, not an opt-out.
    if [ -z "$token" ]; then
        error_message "    ⚠️  No t3-logs token for this unit (missing from ${T3_BACKUP_ENV}?); result not reported"
        return 0
    fi

    local observed_at payload_file config_file response_file code attempt delay
    observed_at=$(t3b_madrid_now)

    payload_file=$(mktemp)
    config_file=$(mktemp)
    response_file=$(mktemp)
    chmod 600 "$config_file"

    if [ "$status" = "succeeded" ]; then
        jq -n \
            --arg event_id "$event_id" \
            --arg observed_at "$observed_at" \
            --arg started_at "$started_at" \
            --arg artifact_location "$artifact" \
            --argjson item_count "${item_count:-0}" \
            --argjson size_bytes "${size_bytes:-0}" \
            '{event_id: $event_id, observed_at: $observed_at, started_at: $started_at,
              status: "succeeded", artifact_location: $artifact_location,
              item_count: $item_count, size_bytes: $size_bytes, error: null}' \
            > "$payload_file"
    else
        jq -n \
            --arg event_id "$event_id" \
            --arg observed_at "$observed_at" \
            --arg started_at "$started_at" \
            --arg error "$error" \
            '{event_id: $event_id, observed_at: $observed_at, started_at: $started_at,
              status: "failed", artifact_location: null,
              item_count: null, size_bytes: null, error: $error}' \
            > "$payload_file"
    fi

    # The token goes in a 0600 curl config, not on the command line, where any
    # user on the machine could read it out of ps.
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$config_file"

    attempt=0
    delay=5
    while :; do
        code=$(curl --silent --show-error \
            --config "$config_file" \
            --header 'Content-Type: application/json' \
            --data-binary @"$payload_file" \
            --max-time 15 \
            --output "$response_file" \
            --write-out '%{http_code}' \
            "$T3LOGS_ENDPOINT") || code="000"

        case "$code" in
            200|202)
                break
                ;;
            408|429|5??|000)
                # Temporary; retry with backoff.
                ;;
            *)
                error_message "    ⚠️  t3-logs rejected the result (${code}): $(cat "$response_file")"
                break
                ;;
        esac

        attempt=$((attempt + 1))
        if [ "$attempt" -ge 6 ]; then
            error_message "    ⚠️  t3-logs unreachable after ${attempt} attempts (last status ${code}); event_id=${event_id}"
            break
        fi

        sleep "$delay"
        delay=$((delay * 2))
    done

    rm -f "$payload_file" "$config_file" "$response_file"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

t3b_title() {
    echo "======================================="
    echo "=          T3 Backup v${T3_BACKUP_VERSION}           ="
    echo "======================================="
    echo ""
}

t3b_check_env() {
    if [ -z "${T3_BACKUP_PATH}" ]; then
      error_message "T3_BACKUP_PATH is not set or is empty"
      exit 1
    fi

    if [ -z "${MEILI_API_KEY}" ]; then
      error_message "MEILI_API_KEY is not set in ${T3_BACKUP_ENV}"
      exit 1
    fi

    echo "Root Path: ${T3_BACKUP_PATH}"
}

t3b_check_deps() {
    local missing=""

    for cmd in curl jq uuidgen; do
        command -v "$cmd" >/dev/null 2>&1 || missing="${missing} ${cmd}"
    done

    if [ -n "$missing" ]; then
        error_message "Missing required commands:${missing}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Backup units
# ---------------------------------------------------------------------------

t3b_postgres_db() {
    local db="$1" token="$2"

    local backup_dir="${T3_BACKUP_PATH}/postgres"
    mkdir -p "${backup_dir}"

    local artifact="${backup_dir}/$(date +%Y%m%d)_${db}"
    local event_id started_at stderr_log

    event_id=$(t3b_uuid)
    started_at=$(t3b_madrid_now)
    stderr_log=$(mktemp)

    echo "    📦 Dumping ${db}..."

    if pg_dump -Fc \
        -h "${POSTGRES_HOST}" \
        -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" \
        -d "${db}" \
        -f "${artifact}" 2>"${stderr_log}"; then
        t3b_report "$token" "$event_id" "$started_at" "succeeded" \
            "$artifact" 1 "$(t3b_file_size "$artifact")" ""
    else
        T3B_EXIT_CODE=1
        error_message "    ❌ Dump of ${db} failed"
        t3b_report "$token" "$event_id" "$started_at" "failed" "" "" "" \
            "$(t3b_error_text "$stderr_log" "pg_dump failed without writing to stderr")"
    fi

    rm -f "${stderr_log}"
}

t3b_postgres_prune() {
    local backup_dir="${T3_BACKUP_PATH}/postgres"

    echo "    🧹 Removing dumps older than ${POSTGRES_RETENTION_DAYS} days..."
    find "${backup_dir}" -type f -mtime "+${POSTGRES_RETENTION_DAYS}" -exec rm {} \;
}

t3b_minio_bucket() {
    local bucket="$1" token="$2"

    # One directory per bucket, so each unit can be measured and reported on
    # its own.
    local backup_dir="${T3_BACKUP_PATH}/minio/${bucket}"
    mkdir -p "${backup_dir}"

    local event_id started_at stderr_log

    event_id=$(t3b_uuid)
    started_at=$(t3b_madrid_now)
    stderr_log=$(mktemp)

    echo "    🪣 Dumping bucket ${bucket}..."

    if ${MINIO_CLIENT} mirror "prod/${bucket}" "${backup_dir}" 2>"${stderr_log}"; then
        t3b_report "$token" "$event_id" "$started_at" "succeeded" \
            "$backup_dir" "$(t3b_dir_count "$backup_dir")" "$(t3b_dir_size "$backup_dir")" ""
    else
        T3B_EXIT_CODE=1
        error_message "    ❌ Mirror of bucket ${bucket} failed"
        t3b_report "$token" "$event_id" "$started_at" "failed" "" "" "" \
            "$(t3b_error_text "$stderr_log" "${MINIO_CLIENT} mirror failed without writing to stderr")"
    fi

    rm -f "${stderr_log}"
}

t3b_git_repo() {
    local repo="$1" token="$2"

    local backup_dir="${T3_BACKUP_PATH}/git"
    mkdir -p "${backup_dir}"

    local repo_folder
    repo_folder=$(basename "${repo}" .git)

    local event_id started_at stderr_log

    event_id=$(t3b_uuid)
    started_at=$(t3b_madrid_now)
    stderr_log=$(mktemp)

    echo "    🗃️  Dumping repository ${repo} into ${repo_folder}..."

    # Subshell so a failed cd cannot leak into the next unit.
    if (
        cd "${backup_dir}" || exit 1
        if [ -d "${repo_folder}" ]; then
            cd "${repo_folder}" || exit 1
            git fetch --all && git pull
        else
            git clone "${repo}"
        fi
    ) 2>"${stderr_log}"; then
        t3b_report "$token" "$event_id" "$started_at" "succeeded" \
            "${backup_dir}/${repo_folder}" 1 \
            "$(t3b_dir_size "${backup_dir}/${repo_folder}")" ""
    else
        T3B_EXIT_CODE=1
        error_message "    ❌ Backup of ${repo} failed"
        t3b_report "$token" "$event_id" "$started_at" "failed" "" "" "" \
            "$(t3b_error_text "$stderr_log" "git failed without writing to stderr")"
    fi

    rm -f "${stderr_log}"
}

# Meilisearch is one backup unit split across two calls: the snapshot is asked
# for at the start of the run and pulled at the end, to give it time to finish.
# The snapshot request and the sync are reported together, as one event.
T3B_MEILI_EVENT_ID=""
T3B_MEILI_STARTED_AT=""
T3B_MEILI_ERROR=""

t3b_meili_schedule_backup() {
    echo "✅ Scheduling Meili snapshot..."

    T3B_MEILI_EVENT_ID=$(t3b_uuid)
    T3B_MEILI_STARTED_AT=$(t3b_madrid_now)
    T3B_MEILI_ERROR=""

    local stderr_log
    stderr_log=$(mktemp)

    if ! curl --silent --show-error --fail \
        -X POST \
        -H "Authorization: Bearer ${MEILI_API_KEY}" \
        "${MEILI_URL}/snapshots" 2>"${stderr_log}"; then
        T3B_MEILI_ERROR=$(t3b_error_text "$stderr_log" "snapshot request to ${MEILI_URL}/snapshots failed")
        error_message "    ❌ Meili snapshot request failed"
    fi

    rm -f "${stderr_log}"
}

t3b_meili_sync_backup() {
    local token="$1"

    echo "✅ Syncing Meili..."

    local backup_dir="${T3_BACKUP_PATH}/meili"
    mkdir -p "${backup_dir}"

    local stderr_log
    stderr_log=$(mktemp)

    # A snapshot that was never scheduled cannot have been synced.
    if [ -n "$T3B_MEILI_ERROR" ]; then
        T3B_EXIT_CODE=1
        t3b_report "$token" "$T3B_MEILI_EVENT_ID" "$T3B_MEILI_STARTED_AT" "failed" "" "" "" \
            "$T3B_MEILI_ERROR"
        rm -f "${stderr_log}"
        return
    fi

    if rsync -avz "${MEILI_SNAPSHOT_HOST}:${MEILI_SNAPSHOT_PATH}" "${backup_dir}" 2>"${stderr_log}"; then
        t3b_report "$token" "$T3B_MEILI_EVENT_ID" "$T3B_MEILI_STARTED_AT" "succeeded" \
            "$backup_dir" "$(t3b_dir_count "$backup_dir")" "$(t3b_dir_size "$backup_dir")" ""
    else
        T3B_EXIT_CODE=1
        error_message "    ❌ Meili sync failed"
        t3b_report "$token" "$T3B_MEILI_EVENT_ID" "$T3B_MEILI_STARTED_AT" "failed" "" "" "" \
            "$(t3b_error_text "$stderr_log" "rsync of Meili snapshots failed without writing to stderr")"
    fi

    rm -f "${stderr_log}"
}

# ---------------------------------------------------------------------------
# Run
#
# One line per backup unit. Comment out what should not run.
# ---------------------------------------------------------------------------

t3b_title
t3b_check_env
t3b_check_deps

# --- Meilisearch snapshot: scheduled first so it is ready by sync time ---
t3b_meili_schedule_backup

# --- PostgreSQL databases ---
t3b_postgres_db "spc_devel" "${T3LOGS_TOKEN_PG_SPC_DEVEL}"
t3b_postgres_db "spc_main" "${T3LOGS_TOKEN_PG_SPC_MAIN}"
t3b_postgres_db "topgroup" "${T3LOGS_TOKEN_PG_TOPGROUP}"
t3b_postgres_db "topgroup_emails" "${T3LOGS_TOKEN_PG_TOPGROUP_EMAILS}"
t3b_postgres_db "topgroup_fit" "${T3LOGS_TOKEN_PG_TOPGROUP_FIT}"
t3b_postgres_db "toprock" "${T3LOGS_TOKEN_PG_TOPROCK}"
t3b_postgres_db "toprock_emails" "${T3LOGS_TOKEN_PG_TOPROCK_EMAILS}"
t3b_postgres_db "toprock_fit" "${T3LOGS_TOKEN_PG_TOPROCK_FIT}"

# Drop dumps older than the retention window, once all databases are done.
t3b_postgres_prune

# --- MinIO buckets ---
# A "nop" token backs the bucket up without reporting to t3-logs:
# the toptown-* buckets have no backup resource registered yet.
t3b_minio_bucket "topgroup" "${T3LOGS_TOKEN_MINIO_TOPGROUP}"
t3b_minio_bucket "topgroup-emails" "${T3LOGS_TOKEN_MINIO_TOPGROUP_EMAILS}"
t3b_minio_bucket "toprock" "${T3LOGS_TOKEN_MINIO_TOPROCK}"
t3b_minio_bucket "toprock-emails" "${T3LOGS_TOKEN_MINIO_TOPROCK_EMAILS}"
t3b_minio_bucket "spc" "nop"

# --- Git repositories ---
t3b_git_repo "git@github.com:topgroupx/accounting-history.git" "${T3LOGS_TOKEN_GIT_ACCOUNTING_HISTORY}"
t3b_git_repo "git@github.com:topgroupx/accounting-linter.git" "${T3LOGS_TOKEN_GIT_ACCOUNTING_LINTER}"
t3b_git_repo "git@github.com:topgroupx/docker-django.git" "${T3LOGS_TOKEN_GIT_DOCKER_DJANGO}"
t3b_git_repo "git@github.com:topgroupx/server-backup.git" "${T3LOGS_TOKEN_GIT_SERVER_BACKUP}"
t3b_git_repo "git@github.com:topgroupx/server-dotfiles.git" "${T3LOGS_TOKEN_GIT_SERVER_DOTFILES}"
t3b_git_repo "git@github.com:topgroupx/server-production-2.git" "${T3LOGS_TOKEN_GIT_SERVER_PRODUCTION_2}"
t3b_git_repo "git@github.com:topgroupx/server-production-3.git" "${T3LOGS_TOKEN_GIT_SERVER_PRODUCTION_3}"
t3b_git_repo "git@github.com:topgroupx/support-kbase.git" "${T3LOGS_TOKEN_GIT_SUPPORT_KBASE}"
t3b_git_repo "git@github.com:topgroupx/t3-backend.git" "${T3LOGS_TOKEN_GIT_T3_BACKEND}"
t3b_git_repo "git@github.com:topgroupx/t3-clients.git" "${T3LOGS_TOKEN_GIT_T3_CLIENTS}"
t3b_git_repo "git@github.com:topgroupx/t3-fit.git" "${T3LOGS_TOKEN_GIT_T3_FIT}"
t3b_git_repo "git@github.com:topgroupx/t3-pricing.git" "${T3LOGS_TOKEN_GIT_T3_PRICING}"
t3b_git_repo "git@github.com:topgroupx/t3-spc.git" "${T3LOGS_TOKEN_GIT_T3_SPC}"

# --- Meilisearch sync: reports the snapshot scheduled at the top ---
t3b_meili_sync_backup "${T3LOGS_TOKEN_MEILI}"

exit "${T3B_EXIT_CODE}"

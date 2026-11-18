#!/bin/bash
#
# T3 Backup
#
# Every backup unit is a single call at the bottom of this file, taking the
# unit's name. Comment a line out to skip that unit; nothing else needs to
# change. A failing unit does not stop the others: the exit code is 1 if any
# of them failed.

T3_BACKUP_VERSION="2.0.0"
T3_BACKUP_PATH="/srv/backup"

POSTGRES_HOST="37.187.250.111"
POSTGRES_PORT="5432"
POSTGRES_USER="postgres"
POSTGRES_RETENTION_DAYS="10"

MINIO_HOST="37.187.250.111"

# Set to 1 by any failing backup unit; returned as the script's exit code.
T3B_EXIT_CODE=0

error_message() {
  echo $'\e[31m'"$1"$'\e[0m'
}

os=$(uname)
if [ "$os" = "Darwin" ]; then
    MINIO_CLIENT="mc"
elif [ "$os" = "Linux" ]; then
    MINIO_CLIENT="minio-client"
else
    error_message "Unsupported operating system: $os"
    exit 1
fi

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

    echo "Root Path: ${T3_BACKUP_PATH}"
}

# ---------------------------------------------------------------------------
# Backup units
# ---------------------------------------------------------------------------

t3b_postgres_db() {
    local db="$1"

    local backup_dir="${T3_BACKUP_PATH}/postgres"
    mkdir -p "${backup_dir}"

    local artifact="${backup_dir}/$(date +%Y%m%d)_${db}"

    echo "    📦 Dumping ${db}..."

    if ! pg_dump -Fc \
        -h "${POSTGRES_HOST}" \
        -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" \
        -d "${db}" \
        -f "${artifact}"; then
        T3B_EXIT_CODE=1
        error_message "    ❌ Dump of ${db} failed"
    fi
}

t3b_postgres_prune() {
    local backup_dir="${T3_BACKUP_PATH}/postgres"

    echo "    🧹 Removing dumps older than ${POSTGRES_RETENTION_DAYS} days..."
    find "${backup_dir}" -type f -mtime "+${POSTGRES_RETENTION_DAYS}" -exec rm {} \;
}

t3b_minio_bucket() {
    local bucket="$1"

    local backup_dir="${T3_BACKUP_PATH}/minio/${bucket}"
    mkdir -p "${backup_dir}"

    echo "    🪣 Dumping bucket ${bucket}..."

    if ! ${MINIO_CLIENT} mirror "prod/${bucket}" "${backup_dir}"; then
        T3B_EXIT_CODE=1
        error_message "    ❌ Mirror of bucket ${bucket} failed"
    fi
}

t3b_git_repo() {
    local repo="$1"

    local backup_dir="${T3_BACKUP_PATH}/git"
    mkdir -p "${backup_dir}"

    local repo_folder
    repo_folder=$(basename "${repo}" .git)

    echo "    🗃️  Dumping repository ${repo} into ${repo_folder}..."

    # Subshell so a failed cd cannot leak into the next unit.
    if ! (
        cd "${backup_dir}" || exit 1
        if [ -d "${repo_folder}" ]; then
            cd "${repo_folder}" || exit 1
            git fetch --all && git pull
        else
            git clone "${repo}"
        fi
    ); then
        T3B_EXIT_CODE=1
        error_message "    ❌ Backup of ${repo} failed"
    fi
}

# ---------------------------------------------------------------------------
# Run
#
# One line per backup unit. Comment out what should not run.
# ---------------------------------------------------------------------------

t3b_title
t3b_check_env
# --- PostgreSQL databases ---
t3b_postgres_db "spc_devel"
t3b_postgres_db "spc_main"
t3b_postgres_db "topgroup"
t3b_postgres_db "topgroup_emails"
t3b_postgres_db "topgroup_fit"
t3b_postgres_db "toprock"
t3b_postgres_db "toprock_emails"
t3b_postgres_db "toprock_fit"

# Drop dumps older than the retention window, once all databases are done.
t3b_postgres_prune

# --- MinIO buckets ---
t3b_minio_bucket "topgroup"
t3b_minio_bucket "topgroup-emails"
t3b_minio_bucket "toprock"
t3b_minio_bucket "toprock-emails"
t3b_minio_bucket "spc"

# --- Git repositories ---
t3b_git_repo "git@github.com:topgroupx/accounting-history.git"
t3b_git_repo "git@github.com:topgroupx/accounting-linter.git"
t3b_git_repo "git@github.com:topgroupx/docker-django.git"
t3b_git_repo "git@github.com:topgroupx/server-backup.git"
t3b_git_repo "git@github.com:topgroupx/server-dotfiles.git"
t3b_git_repo "git@github.com:topgroupx/server-production-2.git"
t3b_git_repo "git@github.com:topgroupx/server-production-3.git"
t3b_git_repo "git@github.com:topgroupx/support-kbase.git"
t3b_git_repo "git@github.com:topgroupx/t3-backend.git"
t3b_git_repo "git@github.com:topgroupx/t3-clients.git"
t3b_git_repo "git@github.com:topgroupx/t3-fit.git"
t3b_git_repo "git@github.com:topgroupx/t3-pricing.git"
t3b_git_repo "git@github.com:topgroupx/t3-spc.git"

exit "${T3B_EXIT_CODE}"

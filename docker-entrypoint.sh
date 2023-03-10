#!/usr/local/bin/dumb-init bash
set -euo pipefail

: ${BRANCH:=master}          # Branch to work with when syncing
: ${CHOWN_UID:=}             # ID of the user to chown the repo files to
: ${CHOWN_GID:=${CHOWN_UID}} # ID of the group to chown the repo files to
: ${INTERVAL:=300}           # How often to sync with remote
: ${LOCAL_DIR:=/data}        # Where to find the data to backup
: ${NETRC_CONTENT:=}         # Content to put into .netrc file, base64 encoded
: ${PING_DOWN:=}             # Send a ping (HTTP GET) to this URL when an exit-error ocurred
: ${PING_MAX_TIME:=5}        # Time in seconds to timeout the ping request
: ${PING_UP:=}               # Send a ping (HTTP GET) to this URL when backup finished successfully
: ${REMOTE:=}                # Remote to sync the branch to

function error() {
  if [[ -n $PING_DOWN ]]; then
    curl -sS -m ${PING_MAX_TIME} -o /dev/null "${PING_DOWN}"
  fi

  log E "$@"
}

function fatal() {
  log F "$@"
  exit 1
}

function info() {
  log I "$@"
}

function log() {
  local level=$1
  shift
  echo "[$(date +%H:%M:%S)][$level] $@" >&2
}

function main() {
  pushd "${LOCAL_DIR}"

  [[ -z $NETRC_CONTENT ]] || {
    info "Creating .netrc from ENV..."
    echo "${NETRC_CONTENT}" | base64 -d >~/.netrc
    chmod 0600 ~/.netrc
  }

  info "Marking local dir save..."
  git config --global --add safe.directory "$(pwd)"

  case "${1:-help}" in
  sync)
    run_sync || fatal "Backup failed."
    ;;

  restore)
    run_restore || failed "Restore failed."
    ;;

  *)
    usage
    fatal "Action ${1:-help} called"
    ;;
  esac
}

function run_restore() {
  if [[ -d .git ]]; then
    info "Found .git directory, skipping restore."
    return 0
  fi

  info "Initializing empty git repository..."
  git init -b ${BRANCH}

  info "Setting up remote..."
  git remote add origin "${REMOTE}"

  info "Fetching remote to reset..."
  git fetch origin ${BRANCH} || {
    error "Fetch failed (exit $?)"
    continue
  }

  info "Resetting to remote state..."
  git reset --hard FETCH_HEAD
  git branch -u origin/"${BRANCH}" "${BRANCH}"

  [[ -z $CHOWN_UID ]] || chown -R ${CHOWN_UID}:${CHOWN_GID} .
}

function run_sync() {
  while true; do
    next_run=$((INTERVAL - $(date +%s) % INTERVAL))
    info "Sleeping ${next_run}s to next sync..."
    sleep ${next_run}

    info "Fetching remote to rebase..."
    git fetch ${REMOTE} ${BRANCH} || {
      error "Fetch failed (exit $?)"
      continue
    }

    info "Rebasing upon remote..."
    git rebase FETCH_HEAD || {
      error "Rebase failed (exit $?)"
      continue
    }
    [[ -z $CHOWN_UID ]] || chown -R ${CHOWN_UID}:${CHOWN_GID} .

    info "Pushing to remote..."
    git push ${REMOTE} ${BRANCH} || {
      error "Push failed (exit $?)"
      continue
    }

    if [[ -n $PING_UP ]]; then
      curl -sS -m ${PING_MAX_TIME} -o /dev/null "${PING_UP}"
    fi
  done
}

function usage() {
  cat >&2 <<EOF
Usage:
  docker run --rm -ti \
    -v /mydata:/data:ro \
    -w /data \
    -e REMOTE_HOST=user@host \
    pvc-git <sync|restore>
EOF
}

main "$@"

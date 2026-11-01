#!/usr/bin/env bash
# sync.sh — push/pull this repo to a GitHub repo using a token kept in
# .sync.env, without configuring any account on the machine.
#
#   bash sync.sh pull
#   bash sync.sh push            # pushes commits already made
#   bash sync.sh force-push SHA  # overwrite remote branch, only if it is still at SHA
#
# .sync.env (gitignored, never committed, never pasted into chat):
#   GITHUB_REPO_URL=https://github.com/<user>/<repo>.git
#   GITHUB_USER=<user>
#   GITHUB_PAT=<fine-grained token: this repo only, Contents read/write>
#   GIT_NAME=<name for commits>
#   GIT_EMAIL=<email for commits>
#
# The token is handed to git through a temporary GIT_ASKPASS helper that reads
# it from the environment of that one git process. It never appears in the
# URL, the command line (process list), .git/config, global git config or a
# credential store; credential.helper is blanked so no store is consulted.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVF="$ROOT/.sync.env"
[[ -f $ENVF ]] || { echo "missing $ENVF (see header)" >&2; exit 1; }
git -C "$ROOT" check-ignore -q .sync.env || { echo ".sync.env is not gitignored — refusing" >&2; exit 1; }
set -a; source "$ENVF"; set +a
: "${GITHUB_REPO_URL:?} ${GITHUB_USER:?} ${GITHUB_PAT:?} ${GIT_NAME:?} ${GIT_EMAIL:?}"
[[ $GITHUB_REPO_URL == https://* && $GITHUB_REPO_URL != *@* ]] \
  || { echo "GITHUB_REPO_URL must be a plain https URL without credentials" >&2; exit 1; }

ASK=$(mktemp); trap 'rm -f "$ASK"' EXIT
printf '#!/bin/sh\ncase "$1" in Username*) printf %%s "$SYNC_USER";; *) printf %%s "$SYNC_PAT";; esac\n' > "$ASK"
chmod 700 "$ASK"

g() {
  SYNC_USER="$GITHUB_USER" SYNC_PAT="$GITHUB_PAT" GIT_ASKPASS="$ASK" GIT_TERMINAL_PROMPT=0 \
    git -C "$ROOT" -c credential.helper= -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" "$@"
}
BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)

case ${1:-} in
  pull) g pull --ff-only "$GITHUB_REPO_URL" "$BRANCH" ;;
  push) g push "$GITHUB_REPO_URL" "HEAD:$BRANCH" ;;
  force-push) g push --force-with-lease="$BRANCH:${2:?usage: sync.sh force-push <expected remote sha>}" "$GITHUB_REPO_URL" "HEAD:$BRANCH" ;;
  *) echo "usage: bash sync.sh pull|push|force-push SHA" >&2; exit 1 ;;
esac

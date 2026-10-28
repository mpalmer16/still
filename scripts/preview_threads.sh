#!/bin/sh
# One preview container, one disposable named volume, no host writing mounts.
set -eu
cd "$(dirname "$0")/.."
case "${1:-start}" in
  start)
    docker compose -f compose.threads.yaml up --build --detach --wait
    docker compose -f compose.threads.yaml exec -T still /app/bin/still rpc 'Code.eval_file("/app/preview/seed.exs")'
    printf '\nStill preview: http://localhost:%s/threads\nOnly invented writing is loaded. Your usual Still collection is untouched.\n' "${STILL_PREVIEW_PORT:-4097}"
    ;;
  stop)
    docker compose -f compose.threads.yaml stop
    ;;
  remove)
    docker compose -f compose.threads.yaml down --volumes --rmi all
    ;;
  *)
    printf 'Usage: %s [start|stop|remove]\n' "$0" >&2
    exit 1
    ;;
esac

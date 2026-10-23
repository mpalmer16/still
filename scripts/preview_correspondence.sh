#!/bin/sh
# Always creates a fresh synthetic collection; never reads the normal Still profile.
set -eu
cd "$(dirname "$0")/.."
still_preview_root="$(mktemp -d /tmp/still-correspondence-XXXXXX)"
export MIX_ENV=dev
export STILL_CORRESPONDENCE_PREVIEW_DIRECTORY="$still_preview_root"
export STILL_DATABASE_PATH="$still_preview_root/still.db"
export STILL_LOCAL_STATE_DIRECTORY="$still_preview_root/state"
export PORT="${STILL_PREVIEW_PORT:-4096}"
printf 'Synthetic preview folder: %s\nPreview address: http://localhost:%s/correspondence\n' "$still_preview_root" "$PORT"
mix ecto.create --quiet
mix ecto.migrate --quiet
mix run scripts/seed_correspondence_preview.exs
exec mix phx.server

#!/bin/sh
set -eu
umask 077
mkdir -p /app/data
chmod 700 /app/data

if [ ! -s /app/data/.secret_key_base ]; then
  openssl rand -base64 64 | tr -d '\n' > /app/data/.secret_key_base
fi

export SECRET_KEY_BASE="$(cat /app/data/.secret_key_base)"
exec /app/bin/still start

#!/bin/sh
# One backup pass, run by a Railway cron job: dump each production database,
# check the dump is readable, encrypt it with age, upload it to Cloudflare R2.
# Exits non-zero if any database failed, so Railway shows the run as failed.
set -eu

: "${EMR_DATABASE_URL:?missing}"
: "${ADMIN_DATABASE_URL:?missing}"
: "${R2_ENDPOINT:?missing (https://<account-id>.r2.cloudflarestorage.com)}"
: "${R2_BUCKET:?missing}"
: "${R2_ACCESS_KEY_ID:?missing}"
: "${R2_SECRET_ACCESS_KEY:?missing}"
: "${AGE_RECIPIENT:?missing (age public key, age1...)}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
# Newer aws-cli sends checksum headers R2 may reject; only send them when required.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

STAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
DAY=$(date -u +%Y/%m/%d)
WORK=$(mktemp -d)
# The plain dump only lives here for a few seconds, inside this run's container.
trap 'rm -rf "$WORK"' EXIT

# Optional dead-man switch (e.g. healthchecks.io): alerts you if a run fails
# OR never happens, which is how the old GitHub backup broke unnoticed.
ping() {
  [ -n "${HEALTHCHECK_PING_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 "${HEALTHCHECK_PING_URL}$1" >/dev/null || true
}

backup_one() {
  name=$1
  url=$2
  raw="$WORK/$name.dump"
  out="$WORK/$name-$STAMP.dump.age"

  pg_dump -Fc -d "$url" -f "$raw" || return 1
  pg_restore -l "$raw" >/dev/null || return 1
  age -r "$AGE_RECIPIENT" -o "$out" "$raw" || return 1
  rm -f "$raw"
  (cd "$WORK" && sha256sum "$(basename "$out")" >"$out.sha256") || return 1

  for f in "$out" "$out.sha256"; do
    aws s3 cp "$f" "s3://$R2_BUCKET/$name/$DAY/$(basename "$f")" \
      --endpoint-url "$R2_ENDPOINT" --only-show-errors || return 1
  done
  echo "ok: $name -> $name/$DAY/$(basename "$out") ($(du -h "$out" | cut -f1))"
}

ping /start
failed=0
backup_one emr "$EMR_DATABASE_URL" || { echo "FAILED: emr" >&2; failed=1; }
backup_one admin "$ADMIN_DATABASE_URL" || { echo "FAILED: admin" >&2; failed=1; }

if [ "$failed" -eq 0 ]; then ping ""; else ping /fail; fi
exit "$failed"

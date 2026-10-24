#!/bin/sh
# One backup pass, run by a Railway cron job: dump each production database,
# test-restore it into a throwaway local Postgres, encrypt it with age, upload
# it to Cloudflare R2. Exits non-zero if any database failed, so Railway shows
# the run as failed.
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
PGCHECK="$WORK/pgcheck"

stop_check_db() {
  if [ -f "$PGCHECK/postmaster.pid" ]; then
    pg_ctl -D "$PGCHECK" -m immediate -w stop >/dev/null 2>&1 || true
  fi
  rm -rf "$PGCHECK"
}
# The plain dump and the test restore only live here for a few seconds,
# inside this run's container.
trap 'stop_check_db; rm -rf "$WORK"' EXIT

# Tables and total rows, counted exactly (counts only, no row data).
COUNT_SQL="select count(*) || ' tables, ' || coalesce(sum((xpath('/row/c/text()',
  query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name),
  false, true, '')))[1]::text::bigint), 0) || ' rows'
  from information_schema.tables
  where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')"

# Restore the dump into a fresh Postgres inside this container (never production)
# and check every table in the dump came back without errors. The private key is
# deliberately not in Railway, so this tests the dump, not decryption.
restore_check() {
  raw=$1
  expected=$(pg_restore -l "$raw" | grep -c ' TABLE DATA ') || true
  # Startup chatter (harmless locale warnings) goes to a log, printed only on failure.
  log="$WORK/pgcheck.log"
  if ! { initdb -D "$PGCHECK" -U postgres --auth=trust --no-locale -E UTF8 &&
    pg_ctl -D "$PGCHECK" -l "$log" -w start \
      -o "-k $WORK -c listen_addresses='' -c shared_buffers=32MB"; } >>"$log" 2>&1; then
    cat "$log" >&2
    return 1
  fi
  errors=$(pg_restore --no-owner --no-privileges -h "$WORK" -U postgres -d postgres "$raw" 2>&1 \
    | grep -c 'error:') || true
  summary=$(psql -h "$WORK" -U postgres -d postgres -tAc "$COUNT_SQL") || summary="? tables"
  stop_check_db
  restored=${summary%% *}
  echo "restore-check: $summary restored (expected $expected tables, $errors errors)"
  [ "$errors" -eq 0 ] && [ "$restored" = "$expected" ]
}

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
  # A failed check still uploads the dump (a suspect backup beats none) but
  # fails the run, so it shows up in Railway.
  check=0
  restore_check "$raw" || check=1
  age -r "$AGE_RECIPIENT" -o "$out" "$raw" || return 1
  rm -f "$raw"
  (cd "$WORK" && sha256sum "$(basename "$out")" >"$out.sha256") || return 1

  for f in "$out" "$out.sha256"; do
    aws s3 cp "$f" "s3://$R2_BUCKET/$name/$DAY/$(basename "$f")" \
      --endpoint-url "$R2_ENDPOINT" --only-show-errors || return 1
  done
  echo "uploaded: $name -> $name/$DAY/$(basename "$out") ($(du -h "$out" | cut -f1))"
  if [ "$check" -ne 0 ]; then
    echo "restore-check FAILED: $name" >&2
    return 1
  fi
  echo "ok: $name"
}

ping /start
failed=0
backup_one emr "$EMR_DATABASE_URL" || { echo "FAILED: emr" >&2; failed=1; }
backup_one admin "$ADMIN_DATABASE_URL" || { echo "FAILED: admin" >&2; failed=1; }

if [ "$failed" -eq 0 ]; then ping ""; else ping /fail; fi
exit "$failed"

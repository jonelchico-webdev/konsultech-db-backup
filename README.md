# konsultech-db-backup

Daily backup of the **production** databases to Cloudflare R2. Runs as a Railway cron job inside the production environment, so it reaches both databases over the private network (no public database port), and replaces the old GitHub Actions backup, which stopped working once the databases went private.

Each run:
1. `pg_dump` (custom format) of emr-be's database (`Postgres`) and admin-api's database (`Postgres-Vmz9`)
2. **Restore check:** restores the dump into a throwaway Postgres inside the same container (never production), and checks every table in the dump came back with no errors
3. Encrypts it with [age](https://age-encryption.org) using a **public** key: the service can't decrypt its own backups
4. Uploads `<db>/<yyyy>/<mm>/<dd>/<db>-<timestamp>.dump.age` plus a `.sha256` file to R2. A dump that fails the restore check is still uploaded (a suspect backup beats none), but the run fails
5. Exits non-zero if either database failed (shows as a failed run in Railway), and optionally pings a dead-man switch

A healthy run logs, per database:

```
restore-check: 23 tables, 1234 rows restored (expected 23 tables, 0 errors)
uploaded: emr -> emr/2026/10/24/emr-2026-10-24T18-00-00Z.dump.age (3.1M)
ok: emr
```

The restore check proves the dump is complete and restorable. It can't prove your **private key** still opens the files (that key is deliberately not in Railway), so do the manual restore below every few months, and whenever the key is moved or re-stored.

## One-time setup

### 1. Cloudflare R2
1. Create a **new private bucket**, e.g. `konsultech-db-backups`. Don't reuse the uploads bucket.
2. Bucket → Settings → **Object lifecycle rules**: delete objects after **30 days** (or what you prefer).
3. R2 → **Manage API tokens** → create a token with **Object Read & Write**, scoped to **this bucket only**. Note the Access Key ID, Secret, and the S3 endpoint `https://<account-id>.r2.cloudflarestorage.com`.

### 2. Encryption key (on your own machine)
```bash
brew install age
age-keygen -o konsultech-backup-key.txt
```
- The `Public key: age1...` line goes into Railway as `AGE_RECIPIENT`.
- **The file itself is the private key. It never goes into Railway, GitHub or R2.** Store it in your password manager plus one more safe place. Without it, every backup is unreadable.

### 3. Railway (production environment only)
1. Production → **New** → **Empty service** (or GitHub repo, if you push this folder to one), named `db-backup`. If Railway adds it to other environments too, remove it there.
2. Deploy the code: from this folder, `railway up --service db-backup --environment production`, or connect the GitHub repo.
3. **Variables:**

| Variable | Value |
|---|---|
| `EMR_DATABASE_URL` | `${{Postgres.DATABASE_URL}}` |
| `ADMIN_DATABASE_URL` | `${{Postgres-Vmz9.DATABASE_URL}}` |
| `R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | `konsultech-db-backups` |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | the bucket-scoped token from step 1 |
| `AGE_RECIPIENT` | `age1...` public key from step 2 |
| `HEALTHCHECK_PING_URL` | optional, e.g. a free healthchecks.io check URL (expects a ping daily) |

4. **Settings:**
   - **Cron schedule:** `0 18 * * *` (18:00 UTC = 02:00 Philippine time, outside clinic hours)
   - **Restart policy:** Never (a cron job should run once and stop)
   - **No public domain**
   - **Resource limit:** 0.5 vCPU / 0.5 GB

### 4. Verify once
Run it manually (Railway → the service → **Run now**, or wait for the schedule), check the logs show two `ok:` lines, and check the files are in the bucket. Then do a test restore (below). An untested backup isn't a backup.

## Restore

Always restore into a **new, empty** database first, never straight over production.

```bash
# 1. Download the .dump.age and .sha256 from R2, then:
sha256sum -c emr-<timestamp>.dump.age.sha256
age -d -i konsultech-backup-key.txt emr-<timestamp>.dump.age > emr.dump

# 2. Restore into an empty database (Postgres 17+ for emr, 18+ for admin)
pg_restore --no-owner --no-privileges -d "<empty database url>" emr.dump

# 3. Delete the plain emr.dump when done: it contains patient data.
```

## After this is running

- Disable, then delete, `emr-be/.github/workflows/backup.yml`, and remove its GitHub secrets (`DATABASE_URL`, R2 keys).
- Delete old `pg-backup` artifacts in emr-be → Actions (unencrypted dumps, kept 90 days by default).
- Once a few nightly backups exist and a restore has worked, delete the old unencrypted September dumps from the old bucket.

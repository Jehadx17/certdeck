# Darb: backup restore test

Script: `darb/deploy/tests/restore-test.sh` (CI job `restore`, commit tag `[restore]`). It runs these steps:
1. Seed the database through the API and SQL.
2. Take a full encrypted pgBackRest backup (AES-256-CBC repo cipher).
3. Write more rows, which reach the backup only through the WAL archive.
4. Delete the database volume.
5. Restore and replay the WAL.
6. Compare the row count and the md5 of every row in `core_review` and `core_doc`.

## Result: passed (CI run 38947441367, 2026-10-16, GitHub ubuntu-24.04 runner, repo on a local volume)

| | |
|---|---|
| Reviews seeded | 500,000 + 10,000 written after the backup (recovered from the WAL archive) |
| Backup | 146.8 MB database, 16.6 MB in the repository (compressed + encrypted), 3.5 s |
| Restore + WAL recovery | 3.1 s |
| Reviews before / after | 510,000 `5aff0b1f98c28d903bdd4362e499fd95` / 510,000 `5aff0b1f98c28d903bdd4362e499fd95` |
| Docs before / after | 20 `0efc804ecf243d6b49ce9d95f769f4bf` / 20 `0efc804ecf243d6b49ce9d95f769f4bf` |
| **Result** | **identical** |

The most writes that can be lost is about 1 minute (`archive_timeout` 60 s).

## Fixed on the way
- `archive_command` failed when the stanza didn't exist, which made Postgres restart in a loop (exit code 103). The
  stanza is now created at initdb (`deploy/initdb-pgbackrest.sh`).
- pgBackRest connected as `postgres`, which isn't the database's user. Now `PGBACKREST_PG1_USER=$POSTGRES_USER`.
- The healthcheck counted the entrypoint's socket-only init server as healthy. It now checks over TCP.

## Still to do (👤 VPS + R2 first)
Repeat the test on a spare VPS against the real R2 repository: set `PGBACKREST_REPO1_TYPE=s3` and the R2 keys, run the
same script, and add the result here. Then run it every quarter (DARB-OPS.md).

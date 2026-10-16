#!/bin/sh
# First boot only (/docker-entrypoint-initdb.d): with archiving on, the stanza must exist before the first WAL segment
# is pushed; otherwise every archive-push fails and Postgres restarts itself every few seconds.
set -eu
[ "${ARCHIVE_MODE:-off}" = "on" ] || exit 0
pgbackrest --stanza=darb stanza-create

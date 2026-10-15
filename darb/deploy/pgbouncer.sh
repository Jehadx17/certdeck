#!/bin/sh
# PgBouncer in transaction mode in front of Postgres. Settings come from the environment (deploy/.env).
set -eu
mkdir -p /tmp/pgb
cat > /tmp/pgb/pgbouncer.ini <<INI
[databases]
${POSTGRES_DB} = host=${PGHOST_REAL:-db} port=5432 dbname=${POSTGRES_DB}
[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /tmp/pgb/userlist.txt
pool_mode = transaction
max_client_conn = ${PGB_MAX_CLIENT_CONN:-1000}
default_pool_size = ${PGB_POOL_SIZE:-40}
max_prepared_statements = 0
server_reset_query =
ignore_startup_parameters = extra_float_digits,options
INI
printf '"%s" "%s"\n' "$POSTGRES_USER" "$POSTGRES_PASSWORD" > /tmp/pgb/userlist.txt
exec pgbouncer /tmp/pgb/pgbouncer.ini

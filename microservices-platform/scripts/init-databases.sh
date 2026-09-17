#!/bin/bash
# Runs automatically when the Postgres container is created (docker-entrypoint-initdb.d).
# Creates a separate database per service within the same Postgres instance.
set -e

for DB in users_db catalog_db orders_db; do
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE $DB;
EOSQL
done

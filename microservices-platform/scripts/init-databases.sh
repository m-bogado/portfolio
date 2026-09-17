#!/bin/bash
# Se ejecuta automaticamente al crear el contenedor de Postgres (docker-entrypoint-initdb.d).
# Crea una base de datos separada por servicio dentro de la misma instancia de Postgres.
set -e

for DB in users_db catalog_db orders_db; do
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE $DB;
EOSQL
done

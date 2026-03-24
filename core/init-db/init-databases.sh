#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- =============================================
    -- 1. Užrakinam default prieigą
    -- =============================================
    -- Nauji useriai nebegali jungtis prie jokios DB be explicit GRANT
    REVOKE CONNECT ON DATABASE "$POSTGRES_DB" FROM PUBLIC;
    REVOKE ALL ON SCHEMA public FROM PUBLIC;

    -- =============================================
    -- 2. Servisų duombazės (izoliuotos)
    -- =============================================

    -- Roundcube
    CREATE USER roundcube WITH PASSWORD '${ROUNDCUBE_DB_PASSWORD}' CONNECTION LIMIT 10;
    CREATE DATABASE roundcube OWNER roundcube;
    REVOKE ALL ON DATABASE roundcube FROM PUBLIC;

    -- Grafana
    CREATE USER grafana WITH PASSWORD '${GRAFANA_DB_PASSWORD}' CONNECTION LIMIT 10;
    CREATE DATABASE grafana OWNER grafana;
    REVOKE ALL ON DATABASE grafana FROM PUBLIC;

    -- Prometheus PostgreSQL exporter (read-only, tik monitoringui)
    CREATE USER postgres_exporter WITH PASSWORD '${POSTGRES_EXPORTER_PASSWORD}' CONNECTION LIMIT 3;
    GRANT pg_monitor TO postgres_exporter;
EOSQL

# =============================================
# 3. Kiekvienai DB — užrakinam public schema
# =============================================
for db in roundcube grafana; do
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-EOSQL
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        GRANT ALL ON SCHEMA public TO $db;
EOSQL
done

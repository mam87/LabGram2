#!/usr/bin/env bash
# Recreate the local staging database from scratch: Supabase stubs -> legacy stubs -> schema.sql
# Usage: staging/reset.sh   (expects a Postgres 16 server on socket /tmp, port 54329, superuser postgres)
set -euo pipefail
cd "$(dirname "$0")/.."
PSQL="psql -h /tmp -p 54329 -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "drop database if exists labgram_staging" -c "create database labgram_staging"
$PSQL -d labgram_staging -f staging/supabase_stubs.sql
$PSQL -d labgram_staging -f staging/legacy_stubs.sql
$PSQL -d labgram_staging -f schema.sql
for f in "$@"; do $PSQL -d labgram_staging -f "$f"; done
echo "staging ready"

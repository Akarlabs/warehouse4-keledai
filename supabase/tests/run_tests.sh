#!/bin/bash
# Uji database di PostgreSQL lokal (butuh psql & server Postgres 15+).
# Pemakaian: DB=nama_db_uji ./supabase/tests/run_tests.sh
set -e
cd "$(dirname "$0")/../.."
DB=${DB:-keledai_test}
dropdb --if-exists "$DB" && createdb "$DB"
for f in supabase/tests/supabase_shim.sql supabase/migrations/*.sql; do
  psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
done
psql -X -A -t -d "$DB" -f supabase/tests/test_flows.sql | grep -E '^(OK |GAGAL|ERROR|=+ SEMUA)'

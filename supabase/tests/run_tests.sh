#!/bin/bash
# Uji database produksi di PostgreSQL lokal (15+).
# Pemakaian: DB=nama_db_uji ./supabase/tests/run_tests.sh
set -e
cd "$(dirname "$0")/../.."
DB=${DB:-k4_test}
dropdb --if-exists "$DB" >/dev/null 2>&1 && createdb "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f supabase/tests/shim.sql >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f supabase/setup.sql >/dev/null
psql -X -A -t -d "$DB" -f supabase/tests/test_setup.sql 2>&1 | grep -E '^(OK |GAGAL|psql|ERROR|=+ SEMUA)'

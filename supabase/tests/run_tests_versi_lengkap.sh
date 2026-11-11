#!/bin/bash
# Uji database VERSI LENGKAP (multi gudang & rak) di folder supabase/migrations.
# Versi yang dipakai aplikasi sekarang adalah supabase/setup.sql (lihat run_tests.sh).
set -e
cd "$(dirname "$0")/../.."
DB=${DB:-keledai_lengkap_test}
dropdb --if-exists "$DB" >/dev/null 2>&1 && createdb "$DB"
for f in supabase/tests/supabase_shim.sql supabase/migrations/*.sql; do
  psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >/dev/null
done
psql -X -A -t -d "$DB" -f supabase/tests/test_flows.sql | grep -E '^(OK |GAGAL|ERROR|=+ SEMUA)'

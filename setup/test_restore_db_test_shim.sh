#!/usr/bin/env bash
# Test senza Docker dello shim pg_restore di restore_db_test.sh (docker stub su PATH).
set -euo pipefail
D="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Estrae lo shim dallo script reale
sed -n "/<<'SHIM'/,/^SHIM$/p" "$D/restore_db_test.sh" | sed '1d;$d' > "$T/pg_restore"; chmod +x "$T/pg_restore"
cat > "$T/docker" <<'S'
#!/usr/bin/env bash
echo "ARGS:$*"; echo "STDIN:$(cat)"
S
chmod +x "$T/docker"
echo "contenuto-dump" > "$T/f.dump"
export PATH="$T:$PATH" SHIM_PG_CONTAINER=pg1
out="$(pg_restore --list "$T/f.dump")"
echo "$out" | grep -q "ARGS:exec -i pg1 pg_restore --list" || { echo "FAIL: args"; exit 1; }
echo "$out" | grep -q "STDIN:contenuto-dump" || { echo "FAIL: stdin"; exit 1; }
if pg_restore -U x -d y "$T/f.dump" 2>/dev/null; then echo "FAIL: altri args accettati"; exit 1; fi
if pg_restore --list 2>/dev/null; then echo "FAIL: --list senza file"; exit 1; fi
echo "OK: test_restore_db_test_shim"

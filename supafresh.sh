#!/bin/bash
# fix-db.sh — Complete fix for fresh Supabase self-hosted installs
# Usage: ./fix-db.sh
# Run from: ~/supabase-project (where docker-compose.yml and .env live)

set -euo pipefail

ENV_FILE=".env"
DB_CONTAINER="supabase-db"
ROLES=(postgres supabase_auth_admin supabase_storage_admin authenticator pgbouncer)

log()  { printf "===> %s\n" "$*"; }
warn() { printf "WARNING: %s\n" "$*" >&2; }
die()  { printf "ERROR: %s\n" "$*" >&2; exit 1; }

# --- Preflight ---
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found; run from ~/supabase-project"
[ -f "run.sh" ]    || die "run.sh not found; run from ~/supabase-project"

# --- 1. Fix permissions on init SCRIPT files only (NEVER the data dir) ---
log "Fixing permissions on init scripts (data dir untouched)"
find volumes/db -maxdepth 1 -name '*.sql' -exec chmod 644 {} \; 2>/dev/null || true
find volumes/db -maxdepth 1 -name '*.sh'  -exec chmod 755 {} \; 2>/dev/null || true

# --- 2. Ensure DB is running (start it if not) ---
if ! docker compose ps db --format '{{.State}}' 2>/dev/null | grep -q running; then
    log "Database container not running — starting it"
    docker compose up -d --wait db
fi

# --- 3. Generate a 32-char alphanumeric password ---
NEW_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)
echo "Generated password: $NEW_PASS"

# --- 4. Update POSTGRES_PASSWORD in .env ---
if grep -q '^POSTGRES_PASSWORD=' "$ENV_FILE"; then
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$NEW_PASS|" "$ENV_FILE"
else
    echo "POSTGRES_PASSWORD=$NEW_PASS" >> "$ENV_FILE"
fi

# --- 5. Apply password only to roles that actually exist ---
log "Checking which roles exist..."
ROLE_LIST=$(printf "'%s'," "${ROLES[@]}")
ROLE_LIST="${ROLE_LIST%,}"

mapfile -t EXISTING < <(docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -tAc \
    "SELECT rolname FROM pg_roles WHERE rolname IN (${ROLE_LIST});" \
    | sed '/^[[:space:]]*$/d')

[ "${#EXISTING[@]}" -gt 0 ] || die "No target roles found in the database"

SQL=""
for role in "${EXISTING[@]}"; do
    SQL+="ALTER USER \"${role}\" WITH PASSWORD '${NEW_PASS}'; "
done

printf '===> Applying password to: %s\n' "${EXISTING[*]}"
docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c "$SQL"

# --- 6. Ensure required schemas exist (_realtime & graphql_public) ---
log "Ensuring _realtime and graphql_public schemas exist"
docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL_EOF'
CREATE SCHEMA IF NOT EXISTS _realtime;
ALTER SCHEMA _realtime OWNER TO supabase_admin;
GRANT ALL ON SCHEMA _realtime TO supabase_admin, postgres;
ALTER ROLE supabase_admin SET search_path TO _realtime, public;
ALTER ROLE postgres SET search_path TO _realtime, public;

CREATE SCHEMA IF NOT EXISTS graphql_public;
GRANT USAGE ON SCHEMA graphql_public TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA graphql_public GRANT ALL ON TABLES    TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA graphql_public GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA graphql_public GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;
SQL_EOF

# --- 7. Ensure _supabase database and _supavisor schema exist (fixes pooler) ---
log "Ensuring _supabase database and _supavisor schema exist"
DB_EXISTS=$(docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '_supabase';")

if [ "$DB_EXISTS" != "1" ]; then
    docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE _supabase WITH OWNER supabase_admin;"
fi

docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d _supabase -v ON_ERROR_STOP=1 <<'SQL_EOF'
CREATE SCHEMA IF NOT EXISTS _supavisor;
ALTER SCHEMA _supavisor OWNER TO supabase_admin;
SQL_EOF

# --- 8. Reassign auth schema ownership ---
log "Fixing auth schema ownership"
docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL_EOF'
DO $$
DECLARE r RECORD;
BEGIN
    -- Functions
    FOR r IN SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'auth'
    LOOP
        EXECUTE format('ALTER FUNCTION auth.%I(%s) OWNER TO supabase_auth_admin;', r.proname, r.args);
    END LOOP;
    -- Tables
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'auth' LOOP
        EXECUTE format('ALTER TABLE auth.%I OWNER TO supabase_auth_admin;', r.tablename);
    END LOOP;
    -- Sequences
    FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'auth' LOOP
        EXECUTE format('ALTER SEQUENCE auth.%I OWNER TO supabase_auth_admin;', r.sequencename);
    END LOOP;
END $$;
SQL_EOF

# --- 9. Sync supabase_admin password BEFORE recreating containers ---
log "Syncing supabase_admin password to match .env"
docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
    -c "ALTER USER supabase_admin WITH PASSWORD '${NEW_PASS}';"

# --- 10. Recreate dependent services via run.sh to reload .env ---
log "Recreating dependent services..."
sh run.sh recreate --except db

echo
echo "Done. New POSTGRES_PASSWORD in .env:"
grep '^POSTGRES_PASSWORD=' "$ENV_FILE"
echo
echo "Checking service status:"
sh run.sh status

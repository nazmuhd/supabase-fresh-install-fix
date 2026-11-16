# supabase-fresh-install-fix

One-shot fix script for **fresh self-hosted Supabase installs**. Install,
run this, you're good to go.

## Requirements

- Docker + Docker Compose
- `openssl` (present on virtually every Linux system)
- A fresh Supabase install at `~/supabase-project`

## Usage

**Step 1 — Fresh install of self-hosted Supabase** (official installer):

```bash
curl -fsSL https://supabase.link/setup.sh | sh
```

This creates `~/supabase-project` with `docker-compose.yml`, `.env`, and `run.sh`.

**Step 2 — Copy the script into the folder and run it:**

```bash
cp supafresh.sh ~/supabase-project/
cd ~/supabase-project
chmod +x supafresh.sh
./supafresh.sh
```

That's it. All services should come up healthy.

> ⚠️ **Fresh installs only.** This script resets the database password and
> reassigns schema ownership. Do **not** run it on an existing install you've
> already configured — it will break connections to it.

Re-running is safe: it rotates the password and re-applies fixes harmlessly.

## What you'll see

The script prints each step, the new generated password, and a final
`run.sh status` showing all services healthy.

## Safety notes

- Idempotent: uses `IF NOT EXISTS` / existence checks everywhere possible.
- Passwords are applied to existing roles only — never created from scratch.
- The Postgres data directory is never modified.
- `set -euo pipefail` — the script stops at the first failure instead of
  half-applying changes.

## License

MIT

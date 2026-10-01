# OLA Water ERP

Web-based ERP for OLA Water Sri Lanka — production, quality control, warehouse, bottle tracking (including external-company bottles), deliveries, water shops, finance and a complete audit trail.

Built with Next.js 15, TypeScript, Tailwind CSS and Supabase (PostgreSQL, Auth, Row Level Security). Deployed on Vercel.

The full specification is in [`docs/OLA_Water_ERP_Master_Prompt_v2.md`](docs/OLA_Water_ERP_Master_Prompt_v2.md). Design decisions are logged in [`DECISIONS.md`](DECISIONS.md).

---

## Status

| Phase | Scope | Status |
|---|---|---|
| **0 — Foundation** | Auth, roles & permissions, RLS, audit trail, document numbering, settings, barcode/label service, accounting core (ledger + posting rules) | **Done** |
| 1A — Core bottle & delivery loop | Customers, products, inventory, bottles, external bottles, orders, deliveries, driver app | Next |
| 1B — Water shops & POS | Shops, shop POS, settlements, thermal receipts | |
| 2 — Operations & finance | Production, QC, procurement, accounting UI, HR, fleet | |
| 3 — Commercial & control | Distributors, CRM, complaints, notifications, documents, approvals | |
| 4 — Intelligence | AI assistant, analytics, forecasting | |

### What Phase 0 gives you

- **Sign in** with email and password (no public sign-up, no customer accounts). Failed sign-ins, logins and logouts are audited with IP and device.
- **Permission-based navigation** — each user only sees what their roles allow. The same permissions are enforced again in the database (RLS + checks inside every function), so hiding a menu is never the only protection.
- **Users** — create staff accounts, assign roles (optionally limited to one location), deactivate, set temporary passwords.
- **Roles & Permissions** — 16 default roles from the spec, 69 permissions covering every module; create custom roles.
- **Audit Trail** — every change with user, roles, time, IP, device, reason and a before/after comparison. The table is append-only: the database blocks edits and deletes for everyone.
- **System Settings** — business thresholds and policies, changed with an effective date; history is never overwritten.
- **Label Printing** — generate numbered label batches (`OLA-BTL-00000001`, `EXT-AQUA-00000001`, …) as QR, Data Matrix or Code 128, preview at real size and print on 50×25 / 40×30 / 30×20 mm label printers. Prints and reprints (with reason) are audited.
- **Accounting core** (no screens yet) — chart of accounts, monthly periods with closing, immutable journals with a database-level balance check, and a posting-rules engine that turns business events (cash sale, credit sale, deposit taken, bottle write-off, …) into balanced journal entries. Phase 1 transactions post through it from the first sale.

---

## Setting up

### 1. Create a Supabase project

1. Create a project at supabase.com (region: Singapore is closest to Sri Lanka).
2. **Authentication → Sign In / Providers → Email:** turn **off** "Allow new users to sign up". Staff accounts are created by administrators inside the ERP.
3. Copy the project URL, anon key and service role key from **Project Settings → API**.

### 2. Apply the database migrations

With the [Supabase CLI](https://supabase.com/docs/guides/cli):

```bash
supabase login
supabase init            # keep the existing supabase/migrations folder
supabase link --project-ref <your-project-ref>
supabase db push
```

(Alternatively, run each file in `supabase/migrations/` in order in the SQL Editor.)

### 3. Create the first Super Admin

1. **Authentication → Users → Add user**: enter your email and a password, tick *Auto confirm*.
2. In the **SQL Editor** run:

```sql
select public.bootstrap_super_admin('you@yourcompany.lk');
```

This only works once. After that, add every other user from **Users** inside the ERP.

### 4. Run locally

```bash
cp .env.example .env.local   # fill in the three values
npm install
npm run dev                  # http://localhost:3000
```

### 5. Deploy to Vercel

Import the repository in Vercel and add the same three environment variables. `SUPABASE_SERVICE_ROLE_KEY` must **not** be prefixed with `NEXT_PUBLIC_`.

---

## Testing

```bash
npm run db:test      # runs all migrations + 69 database tests on a throw-away PostgreSQL 16
npm run typecheck
npm run lint
npm run build
```

`db:test` needs PostgreSQL 16 server binaries installed locally (`apt install postgresql-16`). It uses a minimal stand-in for Supabase's `auth` schema (`supabase/tests/00_supabase_stub.sql`) that is never applied to a real project.

The tests cover: permission checks and RLS, function privileges (nothing callable anonymously), audit records with before/after and reason, audit/journal/settings immutability (even for the table owner), gapless document numbering across rollbacks, idempotency (repeated `client_txn_id` returns the original result), label generation/print/reprint/cancel, balanced posting, reversals, closed periods, and effective-dated settings.

---

## Project layout

```
supabase/
  migrations/      0001 audit · 0002 access control · 0003 settings/numbering/idempotency
                   0004 identifiers & labels · 0005 accounting core · 0006 admin RPCs & grants
                   0007 reference data (permissions, roles, chart of accounts, posting rules…)
  tests/           database test suite
src/
  app/(app)/       signed-in screens (home, labels, audit, admin/*)
  app/login/       sign-in
  app/print/       printable label sheets (no app chrome)
  components/ui/   design system (buttons, fields, tables, badges, dialogs, forms)
  lib/             Supabase clients, access control, navigation, formatting, barcodes
scripts/db-test.sh
```

## How business logic is built (rules for every phase)

1. Anything that changes money, stock or bottles is **one PostgreSQL function** running in **one transaction**. Screens call these functions; they never write ledger tables directly.
2. Ledgers are **append-only**. Corrections are reversals with a reason.
3. Every transaction-creating call carries a **`client_txn_id`** (forms add one automatically), so double-clicks, retries and offline re-sync can never create duplicates.
4. Every operational event posts its **journal entry** through `app.post_event(...)` and the `posting_rules` table.
5. Auditing happens in **database triggers**, so no code path can skip it.
6. All thresholds, rates and policies live in **System Settings** with effective dates — nothing is hard-coded.

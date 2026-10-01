# OLA Water ERP

Web-based ERP for OLA Water Sri Lanka — production, quality control, warehouse, bottle tracking (including external-company bottles), deliveries, water shops, finance and a complete audit trail.

Built with Next.js 15, TypeScript, Tailwind CSS and Supabase (PostgreSQL, Auth, Row Level Security). Deployed on Vercel.

The full specification is in [`docs/OLA_Water_ERP_Master_Prompt_v2.md`](docs/OLA_Water_ERP_Master_Prompt_v2.md). Design decisions are logged in [`DECISIONS.md`](DECISIONS.md).

---

## Status

| Phase | Scope | Status |
|---|---|---|
| **0 — Foundation** | Auth, roles & permissions, RLS, audit trail, document numbering, settings, barcode/label service, accounting core (ledger + posting rules) | **Done** |
| **1A — Core bottle & delivery loop** | Customers, products & prices, VAT, inventory, bottles, external bottles, deposits, orders, recurring orders, dispatch, driver app (offline), check-in reconciliation, receipts, dashboard | **Done** |
| **1B — Water shops & POS** | Water shops (company-owned and dealer), stock requests, shop till (offline), head-office counter, daily till closing, settlements, shop statements | **Done** |
| **2A — Production, QC & purchasing** | Materials & bills of materials, production batches, QC holds/tests/release, batch tracing & recalls, suppliers, purchase requests/orders, goods received, 3-way matched supplier invoices, supplier payments, weighted average cost | **Done** |
| **2B — Finance** | Accounting reports (P&L, balance sheet, cash flow, trial balance, ledger, ageing, VAT), manual journals with approval, periods, cash & bank accounts, cheques, payment reversals, credit notes, transfers, card settlements, bank reconciliation, expenses, VAT returns | **Done** |
| 2C — People & assets | HR & payroll, fleet (incl. fuel logs and driver expenses), fixed assets & depreciation | Next |
| 3 — Commercial & control | Distributors, CRM, complaints, notifications, documents, approvals | |
| 4 — Intelligence | AI assistant, analytics, forecasting | |

### What Phase 2B adds

- **Reports** (print / PDF and Excel download) — Profit & Loss with the previous period, Balance Sheet, Cash Flow (by purpose), Trial Balance with opening and closing, General Ledger for any account, customer and supplier ageing (not due / 1–30 / 31–60 / 61–90 / 90+), VAT for a period.
- **Journals** — every entry with its lines and source; reversal with a reason; **manual journals are prepared by one person and approved by another**.
- **Accounting periods** — close a month (nothing can be posted into it afterwards); open new years; chart of accounts can be extended.
- **Banking** — several cash, petty cash and bank accounts (each with its own ledger account); transfers (cash banked, petty cash top-ups), card/QR settlements with commission, bank charges and interest; **bank reconciliation** by ticking items against the statement.
- **Cheques** — cheques received are tracked in hand → deposited (on a deposit slip) → cleared, or **returned** (the customer owes it again and the invoices reopen).
- **Payments & credits** — reverse a payment entered by mistake; **credit notes** for price corrections, leaking bottles or recalled stock (with VAT), unused credit applied to later invoices.
- **Expenses** — categories mapped to expense accounts, receipt photo/PDF, approval above the limit (never by the person who entered it), paid on the spot or recorded as a bill and paid later.
- **VAT returns** — the period's output VAT is cleared against input VAT and the payment to the IRD recorded; excess input VAT is carried forward.

### What Phase 2A adds

- **Materials** — caps, labels, preforms, chemicals, filters and spare parts are stock items (any unit: piece, kg, litre…), with reorder levels and a **bill of materials** per product.
- **Production** — plan a batch on a line, record process stages (RO, UV, ozone, filling…), then finish it: materials used are taken from stock (suggested from the bill of materials), 19L bottles can be scanned so each bottle is traced to its batch, and the output goes on **QC hold** with an expiry date and a real cost per unit.
- **Quality control** — test templates with limits (pH, TDS, turbidity, E. coli…); results outside the limits fail automatically; certificates/lab reports can be uploaded. Only a passed batch can be released; a failed batch goes to **quarantine** and can never be sold unless an authorised manager overrides with a reason (audited). Quarantined stock is destroyed and written off from the batch page.
- **Batch tracing & recalls** — every stock movement records its batch (oldest stock leaves first). A recall pulls all remaining stock into quarantine and lists every customer who received the batch, for follow-up and recovery.
- **Purchasing** — purchase request → approval → purchase order (orders over the purchase limit need approval; printable PO) → goods received (part deliveries, rejects at the door, supplier lot and expiry) → supplier invoice **3-way matched** against order and goods received (mismatches are held for an approver) → supplier payment.
- **Suppliers** — details, price lists, what you owe, overdue, on-time delivery and rejection rates.
- **Costing & accounting** — weighted average cost from purchases and production; journals for goods received (via Goods Received Not Invoiced), supplier invoices (incl. VAT input and price variance), payments, production and QC write-offs.
- **Dashboard & inventory** — stock by status (available / QC hold / quarantine), stock value, low stock, expiring stock, purchases waiting, supplier payables.

### What Phase 1B adds

- **Water shops** — each shop is set as **company-owned** (OLA's stock, OLA's sales, staff paid commission) or **dealer** (the dealer buys stock from OLA at transfer prices and sells under their own name). Each shop gets its own stock location, a pooled walk-in customer and (for dealers) a credit account.
- **Stock requests** — shop asks → office approves (dealer credit is checked) → warehouse dispatches (stock shows as *in transit*) → shop counts what arrived. Any difference becomes an exception; dealers are invoiced only for what they received.
- **Till** (`/pos`, works offline on a tablet, phone or PC) — product tiles, barcode scanning, walk-in or registered customers at their own prices, OLA and other-company empties, deposits and refunds, split payments, change, 80 mm receipt. Receipt numbers are made on the device so the till keeps selling without internet; sales sync exactly once.
- **Head-office counter** — the same till at the warehouse/office for counter sales (new role *Counter Cashier*).
- **Closing the till** — blind count of cash, stock and bottles; every difference becomes an exception (found / cashier owes / write off).
- **Settlements** — company-owned shops bank their takings and accrue commission; dealers pay OLA on account. Printable **shop statement** (Save as PDF) for any period.
- **Shop staff only see their own shop** — roles can be limited to a location.
- **Dashboard** — shop sales today, what dealers owe, requests waiting, stock in transit, bottles at shops.

### What Phase 1A adds

- **Dashboard** — today's sales, cash collected, deliveries, orders waiting, money owed, where bottles are, external bottles held, alerts.
- **Customers** — all ten customer types, addresses with GPS, credit limits (Finance only), payment terms, bottle model (deposit or loan with a limit), policy for other companies' bottles, balances, invoices, payments, bottle history.
- **Products & Prices** — products, effective-dated price lists (tax-inclusive or not), VAT rates by date, bottle deposit / replacement values, customer-type defaults.
- **Orders** — phone/staff orders with live pricing; credit-limit, overdue and bottle-limit checks put orders **on hold** for Finance to release; edits are audited before/after.
- **Recurring orders** — daily, alternate days, weekly on chosen days, every N days, monthly; pause, resume, skip, cancel; generating twice never duplicates.
- **Dispatch** — plan a run from confirmed orders, warehouse load-out with suggested quantities and cash float, driver confirms the load on the phone.
- **Driver app** (`/driver`, phone browser, works offline) — stops in order, call/navigate, deliver with steppers, camera barcode scanning (Android and iPhone) or Bluetooth scanner, OLA and external bottle collection, tag-at-the-door for external bottles, live total incl. deposits, cash/card/QR/bank/cheque/on-account, change, signature or photo, GPS, 80 mm receipt. Offline transactions queue on the phone and sync exactly once.
- **Check-in** — expected vs counted for products, OLA empties, every external company's bottles and cash; every difference becomes an **exception** (found / charge driver / write off), and the run closes when all are resolved.
- **Bottles** — where every OLA bottle is, value outside the warehouse, register labels, opening balances, look up any label with its full history, mark damaged / retire.
- **External bottles** — per-company accounts (collected, returned, held, value, alert), hand-overs with the receiver's name, OLA bottles received back.
- **Inventory** — stock by location (warehouse, each vehicle), receive, transfer, stock count with approval limit.
- **Payments** — office and driver collections, allocation to oldest invoices, receipts and reprints (audited).
- **Accounting** — every invoice, payment, deposit, float, hand-in, shortage, write-off and stock change posts a balanced journal automatically.

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
npm run db:test      # runs all migrations + database tests (Phase 0, 1A, 1B, 2A and 2B scenarios) on a throw-away PostgreSQL 16
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

# Decisions log

Assumptions and decisions made while building, as required by the master prompt (§ How to use this document, rule 5). Newest phase first.

## Phase 0 — Foundation (October 2026)

**D-001 · Business logic in PostgreSQL functions.** All writes to sensitive tables go through `SECURITY DEFINER` functions in `public` that check permissions first. There are no INSERT/UPDATE/DELETE RLS policies for users; RLS is used for reads. This gives one place for every rule and makes the API safe even if someone calls Supabase directly with a user token.

**D-002 · Internal `app` schema.** Helpers (audit writer, posting engine, numbering, idempotency) live in the `app` schema, which is not exposed through the Supabase API. Only `app.current_user_id`, `app.has_permission`, `app.is_super_admin` and `app.today` are executable by signed-in users (they are needed inside RLS policies).

**D-003 · Audit immutability.** `audit_logs`, `journal_entries`, `journal_lines` and `system_settings` have triggers that reject UPDATE, DELETE and TRUNCATE for every role, including the table owner. Direct write privileges are also revoked from `anon`, `authenticated` and `service_role`.

**D-004 · Audit context.** The Next.js server forwards the end user's IP (`x-client-ip`), device description plus a per-browser id cookie (`x-device-id`), and a request id to Supabase on every call, because Supabase otherwise only sees the Vercel server. A determined user calling the API directly could spoof these headers; user identity itself always comes from the verified JWT.

**D-005 · Failed logins** are written with the service role (there is no signed-in user). The function is not executable by `authenticated` or `anon`.

**D-006 · Gapless numbering.** Document numbers (`INV-HQ-2026-000123`) use a locked counter row per document type, location and year, incremented inside the caller's transaction, so a rolled-back transaction does not consume a number. Offline devices will get device-specific receipt ranges in Phase 1B (spec D-4.5).

**D-007 · Idempotency.** `app.idempotency_begin/finish` store the result per `client_txn_id`. A concurrent duplicate waits for the first transaction and returns its stored result; reusing an id for a different operation is an error.

**D-008 · Labels.** Batches of up to 5,000 labels; printed in parts of 250 to keep the browser responsive. Printing must start from the batch page, which records the print (or reprint with a mandatory reason) in the audit trail before labels are shown. QR codes use the highest error correction (H) for scuffed or wet bottles. External-company tag series (`EXT-AQUA`, `EXT-XYZ`, `EXT-ABC`, `EXT-UNK`) are seeded for the demo companies named in the spec; Phase 1A will create a series automatically when an external company is added.

**D-009 · Accounting in Phase 0.** The ledger, posting rules and period controls exist now so that the first Phase 1 sale posts correctly (this fixes the original plan's dependency of Phase 1 on Phase 2 accounting). Accounting screens come in Phase 2. Posting rules for the Phase 1 events are seeded and can be changed with an effective date.

**D-010 · Chart of accounts** is a sensible default for a Sri Lankan manufacturer/distributor (VAT input/output, SSCL, EPF, ETF, PAYE/APIT, bottle deposit liability). **Your accountant should review it before go-live.** Tax rates are not stored anywhere yet — they arrive as effective-dated tax codes with products in Phase 1A.

**D-011 · Settings seeded with placeholder thresholds** (discount approval 10%, purchase approval Rs. 100,000, expense approval Rs. 25,000, stock adjustment 50 units, external-bottle alert 100 per company, inactivity 60 days, unsynced data alert 4 hours). These are read by Phase 1–3 features; **management should set the real values** in System Settings. A session-timeout setting was deliberately not added because it would not be enforced yet — configure session limits in Supabase Auth settings instead.

**D-012 · Deactivation** sets `profiles.is_active = false` (all permissions stop immediately because every check requires an active profile) and also bans the user in Supabase Auth so they cannot sign in again. The last active Super Admin cannot be deactivated or removed.

**D-013 · Navigation shows only built modules.** Future modules are added to `src/lib/nav.ts` as they are built, so there are no menu items that lead nowhere.

**D-014 · English only.** All UI, receipts, documents and notifications are in English.

**D-015 · Fonts.** System font stack (no web-font download), which renders well on Android, iOS and Windows and keeps pages fast on mobile data.

### Not verified in this phase
- The screens were type-checked and production-built, and every database function was tested against PostgreSQL 16, but the app has **not yet been clicked through against a live Supabase project**. Do this right after setup (sign in, create a user, assign a role, generate and print a label batch, change a setting, check the audit trail).
- Label print sizes should be test-printed on the actual label printer before ordering label rolls.

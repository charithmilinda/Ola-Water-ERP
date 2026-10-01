# OLA WATER ERP — MASTER DEVELOPMENT PROMPT (v2)

---

## HOW TO USE THIS DOCUMENT (FOR THE AI DEVELOPER)

This document is the single source of truth for the OLA Water ERP.

1. Read the whole document before writing any code.
2. Build **one phase at a time** (see Part E). Do not start a phase until the previous phase meets its acceptance criteria.
3. At the start of each phase, produce a short plan: the tables, migrations, server functions, screens and tests you will create. Then build them.
4. Everything that touches money, stock or bottles must follow the **Core Architecture Rules** (Part A, Section 4). These rules override any convenience shortcut.
5. When something in this document is ambiguous, choose the safest option for data integrity, write it down in `DECISIONS.md`, and continue.

---

# PART A — FOUNDATIONS

## 1. PROJECT OVERVIEW

Build a complete, production-ready, web-based ERP for **OLA Water Sri Lanka**, a bottled drinking-water manufacturing, distribution, delivery and retail business.

The ERP manages the full lifecycle:

**Production → Quality Control → Warehouse → Inventory → Orders → Sales → Water Shops → Delivery → Bottle Collection → Bottle Reconciliation → Payments → Procurement → Accounting → HR → Fleet → Reporting → Audit**

This is not a CRM, POS, accounting app or inventory system on its own. It is one integrated **water-business ERP**.

### The single most important business problem

> Customers frequently hand back empty bottles that belong to other water companies. The ERP must identify, track, store, reconcile and return those external-company bottles, with complete accountability, and must also track OLA bottles held by customers, shops, drivers and other companies.

Every design decision in the bottle system must serve this problem.

---

## 2. PRODUCT DECISIONS (MANDATORY)

### Do NOT build

* Customer mobile app, customer portal or customer self-service website
* Customer login of any kind
* React Native / Expo apps
* NFC / RFID as the primary identification method

### Build

* Responsive web application only (desktop, tablet, mobile browser), installable as a PWA where useful
* Barcode-based identification (1D and 2D)
* Thermal receipt printing (80mm)
* Water Shop Management with its own POS
* Driver / delivery web interface
* Centralised ERP with full audit trail
* Offline-tolerant operational screens (scoped in Section D-4)

Users access the system from desktop PCs, laptops, Android tablets, Android phones and iPhone Safari. No app-store installation is required.

Customers are managed only by OLA staff, drivers and shop staff through authorised ERP screens.

The architecture must be modular enough that RFID/NFC can be added later as an **additional identifier type** on the same records, without rebuilding the bottle system.

---

## 3. TECHNOLOGY STACK

| Layer | Choice |
|---|---|
| Frontend | Next.js (App Router), React, TypeScript, Tailwind CSS, shadcn/ui |
| Backend | Next.js server actions / route handlers + **PostgreSQL functions (RPC)** for all business transactions |
| Database | Supabase PostgreSQL |
| Auth | Supabase Auth, role-based permissions, Row Level Security |
| Storage | Supabase Storage (private buckets, signed URLs) |
| Hosting | Vercel (app), Supabase (DB, auth, storage) |
| Validation | Zod schemas shared between client and server |
| Data fetching | Server-side pagination/filtering; TanStack Query or equivalent on the client |
| Offline | Service worker + IndexedDB outbox (see D-4) |
| Barcode scanning (camera) | ZXing-based library (works on iOS Safari; do **not** rely on the native `BarcodeDetector` API, which is unavailable on iOS) |
| Charts | Recharts or equivalent |
| Testing | Unit tests for business functions, integration tests for each acceptance scenario, Playwright for key flows |

Storage is used for: documents, invoices, receipts (PDF copies), QC certificates, product images, vehicle/employee/supplier documents, complaint images and delivery proof photos.

---

## 4. CORE ARCHITECTURE RULES (NON-NEGOTIABLE)

These rules exist because money, stock and bottles must never drift out of sync.

1. **Business logic lives in the database layer.** Every operation that changes stock, bottles, money or accounting is a single PostgreSQL function (RPC) running in one database transaction. The UI and API routes call these functions; they never write to ledger tables directly.
2. **Ledgers are append-only.** Stock, bottles, money and accounting are recorded as movements (`inventory_transactions`, `bottle_transactions`, `payments`, `journal_entries`). Balances are derived from movements (materialised in balance tables updated inside the same transaction). No balance is ever edited directly.
3. **No deletes, only reversals.** Posted financial, stock and bottle records are never updated or deleted. Corrections are made with a reversal or adjustment record that references the original, carries a reason and is audit-logged.
4. **Every movement has a from and a to.** Each stock or bottle movement records source location, destination location, quantity/item, user, timestamp, reference document and device.
5. **Idempotency.** Every transaction-creating request carries a client-generated UUID (`client_txn_id`). The server rejects duplicates. This protects against double-taps, retries and offline re-sync.
6. **Document numbering.** Invoices, receipts, orders, delivery notes, stock transfers and settlements use database sequences per document type and per issuing location (e.g. `INV-HQ-2026-000123`, `RCP-SHOP03-2026-004512`). Invoice numbers must be gapless; cancelled documents are kept and marked cancelled.
7. **Accounting from day one.** Every operational transaction posts a journal entry through a **posting rules table** (event type → debit/credit accounts), even in Phase 1. Full accounting screens arrive in Phase 2, but the ledger is correct from the first sale.
8. **Audit by trigger.** Audit logging is done by database triggers plus application context (user, role, device, IP, reason), so no code path can skip it.
9. **Authorisation on the server.** Hiding UI elements is not security. RLS policies and permission checks inside RPCs are mandatory.
10. **Configuration, not constants.** Tax rates, prices, thresholds, approval limits, bottle replacement values, external-bottle policies and notification providers are stored in settings tables with effective dates.

---

## 5. LOCALISATION

* Country: Sri Lanka. Time zone: **Asia/Colombo**. Store all timestamps in UTC; display in local time.
* Currency: **LKR**, displayed as `Rs. 1,250.00`. Architecture supports more currencies later.
* Date format: `DD/MM/YYYY`; time: 12-hour with AM/PM on receipts.
* Phone numbers: stored in E.164 (`+94771234567`), displayed as `077 123 4567`.
* **Tax:** support Sri Lankan VAT and SSCL (and any future levy) as configurable tax codes with **effective-dated rates**. Never hardcode a rate. Support VAT-registered and non-registered customers, tax invoices showing OLA's VAT registration number and the customer's VAT number where applicable, and tax reports per period.
* Language: **English only** for the entire UI, receipts, documents and notifications.

---

## 6. DESIGN DIRECTION

The interface should look and feel like a premium enterprise SaaS product, not a basic admin template.

* Clean, modern, professional, fast
* High information density without clutter
* Strong visual hierarchy and consistent spacing
* Professional tables, dashboards, clear status badges and alerts
* Large touch targets (minimum 44px) on mobile, driver and POS screens
* Easy for non-technical staff: minimal typing, scan-first and tap-first flows

Brand: OLA blue as primary, white/light water-inspired backgrounds, dark navy for key headings, a restrained set of status colours. Avoid heavy gradients. Status must never be shown by colour alone; always pair colour with a label or icon.

Use cards, tables, charts, filters, tabs, drawers and dialogs appropriately.

---

# PART B — IDENTIFICATION & THE BOTTLE SYSTEM

This is the most important part of the ERP.

## 7. BARCODE ARCHITECTURE

The barcode only identifies a record. All business information stays in the database.

### Identifier formats

| Item | Format | Example |
|---|---|---|
| OLA returnable bottle | `OLA-BTL-{8 digits}` | `OLA-BTL-00001245` |
| External bottle (OLA-issued tracking tag) | `EXT-{COMPANYCODE}-{8 digits}` | `EXT-AQUA-00008721` |
| Product (retail unit / case) | SKU barcode (EAN-13 where printed on packaging, otherwise internal) | `OLA-19L` |
| Bulk/crate/pallet | `OLA-CRT-{8 digits}` | `OLA-CRT-00000310` |
| Inventory location / bin | `LOC-{WH}-{BIN}` | `LOC-HQ-A01` |

### Symbology

* Bottle labels: **QR or Data Matrix plus a human-readable code** (2D codes read far more reliably on phone cameras and on curved, wet surfaces). Code 128 is supported for USB/Bluetooth scanners and product labels.
* Every label shows the human-readable ID so staff can type it if the code is damaged.

### Physical labels

* OLA bottle labels must survive washing, sanitising and refilling (durable polyester/heat-resistant labels, or laser/hot-stamp marking). Make the label material a configurable note; the system must support **relabelling**.
* Build a **label printing module**: bulk-generate ID ranges, print to label printers (browser print with label-size CSS templates), record which ranges were printed and applied.

### Scanning

* USB and Bluetooth scanners work as keyboard input: every scan field must accept rapid keyboard-wedge input and auto-submit on Enter.
* Camera scanning on Android and iOS via a ZXing-based library, with continuous-scan mode for collecting many bottles in a row, beep/vibration feedback and duplicate-scan protection within the same session.
* Every scan field has a **manual entry fallback** with a mandatory reason when used.

### Identifier abstraction

Use an `identifiers` table (`identifier_type`: barcode / qr / rfid / nfc, `value`, `entity_type`, `entity_id`, `active`). Bottles, products and crates reference identifiers through this table. This is what allows RFID/NFC to be added later without schema changes.

---

## 8. BOTTLE MODEL

### Two kinds of tracking

1. **OLA bottles — serialised.** Every returnable OLA bottle has a unique ID and a full lifecycle history.
2. **External bottles — serialised on intake.** External bottles do **not** carry OLA barcodes, so they cannot simply be "scanned to identify owner". The intake flow is:
   * Driver/shop staff selects the **owner company** from a visual picker (logo + name + size), or "Unknown brand".
   * The system issues and the staff member applies an **OLA external tracking tag** (`EXT-AQUA-00008721`) from a pre-printed roll.
   * From that point the external bottle is serialised and tracked like any OLA bottle.
   * Optional photo capture on intake (configurable: always / for unknown brands only / never).
3. **Fallback count mode.** A system setting allows external bottles to be tracked **by count per company** instead of per-tag (for times when tags run out or for very low-value bottles). Count-mode movements still use the same ledger, with `bottle_id` null and `owner_company_id` + `quantity` filled. Reports must combine both modes.

### Bottle record

* Bottle ID / identifiers
* Owner company (OLA or external company)
* Bottle type, size, colour/material
* Current status and current location (warehouse, vehicle, customer, shop, external holding, external company)
* Current holder (customer / shop / driver-vehicle / warehouse / company)
* Condition (good, needs inspection, damaged)
* **Fill count** and last wash/sanitise date (OLA bottles)
* **Last filled batch number** (OLA bottles, for recall traceability)
* Manufacture/purchase date, retirement rule (max fills or max age, configurable)
* Last transaction and full history

### Bottle statuses

Warehouse – Empty · Warehouse – Full · In Vehicle · With Customer · At Water Shop · External Holding · Returned to Owner · With External Company (OLA bottles held by competitors) · Damaged · Lost · Written Off · Retired · Unknown / Unlabelled

### Bottle ledger

`bottle_transactions` is the source of truth. Each row records: transaction type, bottle (or company + quantity in count mode), from-location/holder, to-location/holder, related document (order, delivery, sale, exchange, transfer, return-to-owner), user, device, GPS (if mobile), timestamp, reason.

Transaction types include: issue_full, collect_empty, exchange, transfer, load_vehicle, unload_vehicle, receive_warehouse, wash, fill, qc_hold, move_to_external_holding, return_to_owner, receive_from_external_company, mark_damaged, mark_lost, write_off, relabel, retire, found.

Balances (per customer, shop, driver, warehouse and external company) are maintained in balance tables updated in the same database transaction.

### Exception handling

* **Unlabelled/damaged-label OLA bottle:** flow to identify by visual check, issue a replacement label, link it to the old record if the original ID is known (`relabel`), otherwise create a new record flagged "relabelled – origin unknown".
* **Scan of a bottle the system thinks is elsewhere** (e.g. bottle recorded at Customer A scanned at Customer B): accept the scan, record the movement, and raise a **bottle location exception** for review. Never block the driver in the field.
* **Duplicate scan** in the same session: ignore with a visible warning.

---

## 9. CUSTOMER BOTTLE POLICY & DEPOSITS

Make the following configurable per customer type and per customer:

* **Bottle model:** deposit-based (customer pays a refundable deposit per bottle), loan-based (bottles on loan within an allowed limit, no deposit), or sale (non-returnable).
* **Allowed bottle balance** (maximum OLA bottles a customer may hold).
* **Deposit amount** per bottle type (effective-dated).

### External bottle acceptance policy

When a customer hands over an external bottle instead of an OLA bottle, the configured policy decides the outcome (per company and per customer type):

* **Accept as 1-for-1 exchange** (counts as a returned bottle).
* **Accept with a charge** (e.g. partial bottle charge or deposit not refunded).
* **Accept as a gift/no credit** (OLA keeps it for return to owner).
* **Refuse.**

The driver/shop screen shows the policy result before confirming, so staff do not have to remember the rules.

### Deposit accounting

Bottle deposits are a **liability** (customer deposits held), not revenue.

* Deposit taken → Dr Cash/Receivable, Cr Bottle Deposit Liability
* Deposit refunded → reverse
* Bottle lost by customer → deposit forfeited to income (or customer charged replacement value if no deposit)
* Bottle written off internally → expense at replacement value (with approval)

---

## 10. EXTERNAL BOTTLE HOLDING & RECOVERY

### Collection flow

1. Driver/shop collects an empty bottle.
2. Scan. If an OLA ID → record OLA return. If an existing `EXT-` tag → record external return. If no tag → run the external intake flow (Section 8).
3. Apply acceptance policy (Section 9) and update the customer's bottle balance.
4. Bottle moves into the driver's (or shop's) external holding.
5. End of route/day: reconciliation (Section 12).
6. Warehouse receives and **physically verifies** (scan each tagged bottle; count count-mode bottles).
7. Bottles move to the **External Holding Area**, grouped by owner company.
8. Return/hand-over to the owner company is recorded with a **hand-over note** (company representative name, signature/photo, quantities, bottle IDs).

### Reciprocal exchange with other companies

Competitors also collect OLA bottles from their customers. The external company ledger must be **two-way**:

```text
AQUA WATER — BOTTLE ACCOUNT

Their bottles we collected:      50
Their bottles we returned:       35
Their bottles we currently hold: 15

OLA bottles they returned to us: 22
OLA bottles believed held by them: (estimate / declared)

Net position: OLA holds 15 Aqua bottles
```

Support:

* Recording OLA bottles received back from an external company (scanned on receipt, status changes to Warehouse – Empty).
* Swap transactions (we give 20 Aqua, they give 18 OLA) in one hand-over document.
* Per-company statements (PDF) for agreement and sign-off.
* Configurable holding threshold per company that raises an alert.

---

## 11. BOTTLE EXCHANGE

A single exchange transaction captures everything given and received:

Customer gives: 5 Aqua (empty), 2 OLA (empty)
Customer receives: 7 OLA 19L (full)

The one database function must update, atomically:

* Customer OLA bottle balance and deposit position
* Driver/shop bottle inventory (OLA full out, OLA empty in, external in)
* External company ledger
* Product inventory (water sold)
* Sales/invoice lines and journal entries
* Audit trail

---

## 12. DRIVER & SHOP ACCOUNTABILITY

### Route start (load-out)

Record and scan: OLA full bottles loaded, OLA empties carried, external bottles carried, other products, **cash float**. The driver confirms the load-out on their device; the warehouse confirms on theirs. Both confirmations are stored.

### Route end (check-in)

The system calculates **Expected vs Actual** for:

* OLA full bottles (loaded − delivered)
* OLA empties (carried + collected)
* External bottles by company
* Products
* **Cash** (float + cash collected − approved cash expenses on route) vs cash handed in
* Card/QR/bank payments recorded vs confirmed

```text
               Expected   Physical   Difference
OLA full          10         10          0
OLA empty         25         25          0
Aqua               5          5          0
XYZ                3          2         -1
Cash (Rs.)    48,500     48,000       -500
```

Any difference automatically creates a **reconciliation exception** assigned to the Delivery Manager, with resolution options (found, recount, charge to driver, write off with approval). Unresolved exceptions block closing the route as "clean" but never block the warehouse from receiving stock.

The same expected-vs-actual check applies to **water shop daily closing**.

---

## 13. BOTTLE FINANCIAL EXPOSURE

Management sets **replacement values** per bottle type and owner company (effective-dated).

Show on dashboard and reports:

* OLA bottles outside the warehouse (by holder type) and their value
* OLA bottles believed held by external companies
* External bottles held, by company, and their value
* Lost, damaged, written-off bottles (count and value) by period
* Customer and shop bottle balances above allowed limits
* Driver discrepancies (open and resolved)
* Bottle ageing: bottles with no movement in X days (configurable)

---

# PART C — BUSINESS MODULES

## 14. GLOBAL NAVIGATION

Navigation is grouped and filtered by the user's permissions:

* **Overview:** Dashboard, Notifications, Approvals
* **Sales:** Customers, Orders, Sales/POS, Sales Representatives, Distributors/Dealers, Marketing/CRM, Complaints
* **Bottles:** Bottle Management, External Bottles, Bottle Reconciliation, Label Printing
* **Delivery:** Deliveries, Drivers, Routes, Fleet
* **Water Shops:** Shops, Shop POS, Shop Inventory, Shop Settlements
* **Operations:** Production, Quality Control, Inventory, Warehouse, Procurement, Suppliers, Assets
* **Finance:** Payments, Accounting, Expenses, Tax
* **People:** HR & Payroll
* **Insights:** Reports & Analytics, AI Assistant
* **Admin:** Documents, Audit Trail, Users & Roles, System Settings

Drivers and shop cashiers get dedicated simplified layouts, not the full ERP navigation.

---

## 15. DASHBOARD

### KPI cards

Today's sales · Today's orders · Deliveries (total / completed / failed) · Production today · Full bottle stock · Empty bottle stock · External bottles held · Customer outstanding · Supplier outstanding · Shop outstanding · Today's expenses · Estimated gross profit · Open reconciliation exceptions

### Charts

Daily and monthly sales · Sales by product, customer type and shop · Production trend · Delivery performance · Bottle recovery rate · External bottle accumulation by company · Receivables ageing · Expense trend

### Alerts

Low stock · Bottle shortages · External bottles over threshold · Failed deliveries · Customers over credit limit or overdue · Shop outstanding · Vehicle service due · Insurance/licence expiry · Supplier payments due · QC failures / batches on hold · Pending approvals · Unsynced offline transactions older than X hours

Every KPI and alert links to the filtered list behind it. Dashboard figures are computed from real data only.

---

## 16. CUSTOMER MANAGEMENT

Customer types: Household, Office, Hotel, Restaurant, Shop, Supermarket, Institution, Distributor, Water Shop, Corporate.

Fields: customer ID, name, company, contact person, phone(s), email, multiple addresses with GPS and delivery instructions, customer type, VAT number, assigned sales rep, route, credit limit, payment terms, price list, **bottle model, allowed bottle balance, deposit held**, external-bottle policy override, status, notes.

Customer profile shows: orders, deliveries, invoices, payments, outstanding and ageing, bottle balance and bottle history, deposits, complaints, recurring orders, activity timeline.

Duplicate detection on phone number and name + address. New credit customers require approval.

There is NO customer login.

---

## 17. PRODUCT MANAGEMENT

Products: OLA 19L, 5L, 1.5L, 500ml (and cases/packs of smaller sizes), plus future products.

Fields: SKU, barcode(s), name, category, bottle type, size, unit of measure and pack conversion (e.g. 1 case = 12 × 1.5L), returnable/non-returnable, linked bottle type and deposit, cost, tax code, active/inactive, image.

Pricing: multiple **price lists** (retail, dealer, distributor, corporate, shop transfer price, custom), each effective-dated, with optional customer-specific overrides and quantity breaks. Price changes are audit-logged and may require approval.

---

## 18. ORDER MANAGEMENT

Sources: internal staff, sales reps, phone orders, recurring orders, water shops, distributors.

Workflow: **Draft → Confirmed → Picking → Assigned → Loaded → Out for Delivery → Delivered (→ Invoiced) → Paid / Outstanding**, with Failed, Rescheduled and Cancelled branches.

Order lines: products, quantities, expected bottle returns (OLA and external), discounts, delivery charge, notes, requested delivery date/time window.

Checks at confirmation: credit limit, overdue balance, allowed bottle balance, stock availability. Breaches route to approval rather than silently blocking.

Partial delivery is supported (delivered qty vs ordered qty; remainder back-ordered or cancelled).

---

## 19. RECURRING ORDERS

Schedules: daily, alternate days, weekly (chosen weekdays), monthly, custom.

Actions: pause, resume, change quantity, change day, skip next, cancel. A scheduled job generates orders a configurable number of days ahead; generated orders are idempotent (no duplicates if the job re-runs).

---

## 20. SALES & POS (HEAD OFFICE / DEPOT)

Workflow: **Select customer (or walk-in) → Scan product → Quantity → Bottle transaction → Discount → Payment → Receipt**

Payment methods: cash, card, bank transfer, QR payment, credit (on account), split payments, and deposit refund/collection.

Discount above a configurable % requires manager approval (PIN/approval request).

Cash drawer sessions: opening float, sales, cash in/out, closing count, variance.

---

## 21. THERMAL RECEIPTS & PRINTING

Target: **80mm thermal printers**.

Printing approach (implement all three; configurable per device):

1. **Default:** browser print using an 80mm receipt template (works on every device, including iPhone).
2. **Android direct print:** ESC/POS over Web Bluetooth or WebUSB in Chrome for silent, fast printing where supported.
3. **Digital copy:** PDF receipt saved to storage and optionally sent by SMS/WhatsApp link.

Receipt content: OLA logo, issuing location, receipt number, date/time, cashier/driver, customer, items (qty, unit price, line total), discounts, tax breakdown (where VAT invoice), total, payment method(s), tendered, change, outstanding balance, and the bottle section:

```text
OLA bottles returned:        5
OLA bottles issued:         10
External bottles collected:  3  (Aqua 2, XYZ 1)
Your OLA bottle balance:    12
```

Reprints are marked **"REPRINT"** and audit-logged.

---

## 22. WATER SHOP MANAGEMENT

Each water shop has its own account, users (shop manager, cashiers) and dashboard. Shop users can only see their own shop's data (enforced by RLS).

Shop profile: shop ID, name, owner, contact, address, GPS, territory, operating model (company-owned / franchise / dealer), credit limit, payment terms, transfer price list, retail price list, commission/margin rules, status.

Shop dashboard: today's sales, current stock, full/empty/external bottles, outstanding to OLA, payments, gross margin, pending stock requests, open exceptions.

### Shop inventory

Tracked separately from the main warehouse: full OLA bottles by size, empty OLA bottles, other products, damaged bottles, external-company bottles. Every movement has source, destination, quantity, user, timestamp and reference.

### Shop stock request

**Request → Approval → Warehouse picking → Dispatch → In transit → Shop receipt**

Show requested, approved, dispatched, received and difference. Receipt differences create an exception for the warehouse and shop managers.

### Shop POS

Barcode scanning, customer selection (or walk-in), product sale, OLA bottle return, external bottle intake, discounts, payments, credit sale (where allowed), thermal receipt, cash drawer, **daily closing** with expected vs actual for cash, stock and bottles.

### Shop settlement

Track daily sales, cash, credit sales, bank/card/QR, payments to OLA, outstanding, commission/margin, stock value, bottle balances. Generate daily settlement, weekly statement and monthly statement (PDF), each posting the correct journal entries.

---

## 23. DELIVERY MANAGEMENT

Statuses: Pending, Assigned, Loaded, Out for Delivery, Delivered, Partially Delivered, Failed (with reason code), Rescheduled, Cancelled.

Record: driver, helper, vehicle, route, stop sequence, customer, products, bottle transactions, payment, confirmation, notes, GPS, timestamps (arrived, completed).

Failed-delivery reason codes are configurable (customer absent, refused, wrong address, no payment, vehicle issue, etc.).

---

## 24. DRIVER WEB APPLICATION

A mobile-first, simplified interface (PWA, offline-tolerant).

Driver sees: route-start load-out confirmation; today's stops in sequence; customer details, address, phone (tap to call) and map navigation link; order details; products to deliver; **expected bottle returns**; continuous bottle scanning; external bottle intake; payment collection; delivery confirmation; route-end check-in summary.

Delivery confirmation options (configurable per customer type): signature, SMS OTP, photo, GPS and timestamp (always captured when permission is granted).

Large buttons, minimal typing, works one-handed, readable in sunlight (high-contrast mode).

---

## 25. ROUTE MANAGEMENT

Routes, areas, delivery zones, default drivers, vehicles and customers per route, stop order.

Show today's route, pending/completed/failed deliveries, route performance, distance (from GPS trail where available), delivery count, collections and bottle recovery per route.

---

## 26. PRODUCTION MANAGEMENT

Process stages: **Raw water → Filtration → RO → UV → Ozone → Storage → Bottle washing/sanitising → Filling → Capping → Labelling → Finished goods (QC hold)**

Record: production date, batch number, product, planned qty, produced qty, wastage, rejected qty, operator, shift, machine/line, start/end time, materials consumed (caps, labels, preforms, chemicals) which reduce raw-material inventory.

Bottle traceability: when returnable bottles are filled, record **which bottle IDs were filled in which batch** (scan at filling or at crate level). This enables batch recall: "show every customer currently holding bottles from batch X".

---

## 27. QUALITY CONTROL

Configurable test templates with fields and acceptable ranges (pH, TDS, turbidity, microbiological, chemical, other lab tests). Values outside range flag automatically.

Each batch: batch number, production date, tests, result, pass/fail, QC officer, certificate/lab report upload.

**Batches start in QC Hold.** Stock from a held or failed batch cannot be picked, transferred or sold. Release of a failed batch requires an authorised override with reason, and is audit-logged.

**Recall workflow:** mark a batch as recalled → system lists all affected stock locations, shops, drivers and customers → track recovery.

---

## 28. INVENTORY & WAREHOUSE

Items: raw materials, finished goods, empty bottles, full bottles, caps, labels, packaging, cleaning materials, filters, membranes, spare parts, chemicals, damaged goods.

Multiple warehouses and bin locations. Batch/lot tracking and expiry dates for finished goods and chemicals.

Functions: stock in, stock out, transfer, adjustment (with reason and approval above threshold), cycle counts and full stock counts (blind count option), damaged stock, minimum stock and reorder alerts. Stock valuation by weighted average cost.

---

## 29. PROCUREMENT & SUPPLIERS

Workflow: **Purchase request → Approval → Purchase order → Goods received (partial allowed) → Supplier invoice (3-way match) → Payment**

Supplier records: details, products and pricing, credit terms, VAT number, documents, outstanding balance, payment history, performance (on-time, quality issues).

---

## 30. ACCOUNTING & FINANCE

* Chart of Accounts (Sri Lankan-friendly default template, editable)
* General Ledger with journal entries generated by posting rules from every operational event
* Manual journals with approval
* Accounts Receivable and Payable with ageing
* Cash and bank accounts, bank reconciliation
* Bottle Deposit Liability account
* Tax accounts (VAT output/input, SSCL) and tax period reports
* Fixed assets and depreciation
* Accounting periods with **period close/lock** (no posting into closed periods; corrections go into the open period)

Reports: Profit & Loss, Balance Sheet, Cash Flow, Trial Balance, General Ledger, Receivables, Payables, tax reports.

Every journal entry links back to its source document, and every source document shows its journal entries.

---

## 31. PAYMENTS

Receipts from customers, shops and distributors; payments to suppliers. Allocation of payments to invoices (full, partial, on-account), refunds, cheque handling (received, deposited, cleared, returned), and payment reversal with reason.

---

## 32. EXPENSES

Categories: fuel, electricity, water, rent, salaries, vehicle repair, maintenance, marketing, packaging, office, utilities, other (configurable).

Workflow: **Expense → Approval → Payment → Accounting entry**, with receipt photo upload. Driver on-route expenses (e.g. fuel) are captured in the driver app and included in route cash reconciliation.

---

## 33. HR & PAYROLL

Employees, departments, positions, attendance, leave, salary, overtime, allowances, deductions, advances, bonuses, payroll runs and payslips.

Statutory contributions (EPF/ETF and any income-tax withholding) are **configurable rules**, not hardcoded. Payroll posts journal entries. Employee personal and salary data is restricted to HR and authorised management.

---

## 34. SALES REPRESENTATIVES

Leads, visits (with GPS check-in), customers, orders, sales, collections, new customers, targets, performance and commission rules.

---

## 35. DISTRIBUTORS / DEALERS

Profiles, territory, price list, credit limit, orders, stock held, payments, outstanding, bottle balances, performance.

---

## 36. FLEET

Vehicles, assigned drivers, fuel logs, mileage, repairs, maintenance schedules, insurance, revenue licence, emission test, service dates and vehicle profitability. Alerts for service due and document expiry.

---

## 37. ASSETS

RO systems, pumps, filling machines, vehicles, generators, computers, office equipment. Purchase date, value, warranty, location, responsible person, maintenance log, depreciation method, disposal.

---

## 38. COMPLAINTS

Categories: delivery, product, quality, bottle, driver, payment, quantity, shop.

Workflow: **New → Assigned → In Progress → Resolved → Closed**, with priority, SLA timer, responsible employee, resolution notes, images, linked order/batch/bottle. Quality complaints can link to a batch and trigger a QC review.

---

## 39. MARKETING / CRM

Leads, prospects, campaigns, promotions (linked to price rules), customer segments, follow-ups, opportunities, conversion tracking.

---

## 40. DOCUMENTS

Secure storage for contracts, vehicle documents, insurance, employee documents, licences, QC certificates, lab reports, invoices and purchase documents. Private buckets, signed URLs, access by permission, expiry dates with alerts.

---

## 41. NOTIFICATIONS

Types: low stock, order confirmation, delivery updates, payment reminders, overdue invoices, vehicle service, document expiry, external bottle threshold, failed delivery, pending approval, production/QC issues, unsynced offline data.

Channels: in-app (Phase 1), email, SMS and WhatsApp (pluggable providers, configured in settings, with English message templates). Customer-facing messages (order confirmation, OTP, payment reminders) go out by SMS/WhatsApp only; there is no customer login.

All sends are logged with status (queued, sent, failed).

---

## 42. APPROVALS

Configurable approval rules (condition → approver role → levels):

* Purchase above amount → Manager
* Discount above % → Sales Manager
* New credit customer / credit limit increase → Finance
* Expense above amount → Management
* Large inventory adjustment → Warehouse Manager
* Bottle write-off (lost/damaged) → authorised role
* Release of QC-failed batch → Quality + Operations
* Manual journal → Finance Manager
* Price list change → Director

Approvers act from an approvals inbox (desktop and mobile). Every approval/rejection is audit-logged with comments.

---

# PART D — CROSS-CUTTING REQUIREMENTS

## D-1. AUDIT TRAIL (MANDATORY)

Immutable audit log populated by database triggers plus application context.

Fields:

```text
id, timestamp, user_id, user_name, role, action, module,
record_type, record_id, old_values (jsonb), new_values (jsonb),
reason, ip_address, device, location, client_txn_id, request_id
```

Logged actions: login, logout, failed login, create, edit, cancel, reverse, approve, reject, payment, refund, stock adjustment, bottle transaction, price change, permission change, user creation/deactivation, configuration change, receipt reprint, data export.

Before/after view for edits:

```text
FIELD        BEFORE        AFTER
Price        Rs. 450.00    Rs. 475.00
Discount     Rs. 0.00      Rs. 25.00
Payment      Credit        Cash
```

Immutability: the application database role has INSERT-only rights on `audit_logs` (UPDATE/DELETE revoked). Audit viewing is restricted to authorised roles. Each record is traceable to the user, device and transaction that caused it.

---

## D-2. SECURITY

* Supabase Auth, session timeout, optional 2FA for management roles
* Roles and permissions stored in the database; administrators can create custom roles
* RLS on every table: shop users see only their shop, drivers only their routes/deliveries, sales reps only their customers (configurable), HR data only for HR
* Permission checks inside every RPC (server-side), never only in the UI
* Input validation with Zod on the client and checks again in the database
* Private storage with signed URLs
* Rate limiting on auth and sensitive endpoints
* Device registration for POS/driver devices (optional but supported)

### Default roles

Management: Super Admin, Director, Finance Manager, Operations Manager
Operations: Warehouse Manager, Production Manager, Quality Officer, Delivery Manager, Driver, Sales Representative
Commercial: Accountant, Shop Manager, Shop Cashier, Distributor Manager
Administration: HR Manager, Procurement Officer

---

## D-3. SEARCH, FILTERING & EXPORT

Every major table: search, date range, status, customer, shop, user filters, sorting, server-side pagination, export (CSV/Excel/PDF; exports are audit-logged). Never load thousands of records into the browser.

---

## D-4. OFFLINE & CONNECTIVITY RESILIENCE

Supabase does not provide offline sync out of the box, so implement it explicitly and **only for these screens**: Driver app, Shop POS, Head-office POS, bottle scanning/collection, warehouse receiving.

Design:

1. **Local cache** (IndexedDB) of the data each device needs: today's route, customers on that route, product/price lists, policy settings, and the bottle IDs currently assigned to that driver/shop.
2. **Outbox:** every transaction created offline is stored locally with a `client_txn_id`, created timestamp, user and device, and shown with a "Pending sync" badge.
3. **Sync:** when online, the outbox replays in order through the same RPCs used online. The server is idempotent on `client_txn_id`, so retries never duplicate.
4. **Conflict rules:** the server is authoritative for balances. Offline bottle scans that conflict with server state are **accepted and flagged as exceptions** (Section 8), never discarded. Offline sales that exceed credit limits are accepted and flagged for review.
5. **Receipts offline:** use a device-specific receipt number range so offline receipts are unique and printable immediately.
6. **Visibility:** a sync status indicator on every offline-capable screen; managers see devices with unsynced data older than a threshold.
7. Logging out or clearing data is blocked while unsynced transactions exist (with a clear warning).

Never silently lose a sale, payment or bottle transaction.

---

## D-5. HARDWARE

| Location | Devices |
|---|---|
| Office | PCs/laptops, USB barcode scanners, A4 printers |
| Warehouse | Android tablets, USB/Bluetooth scanners, label printer, thermal printer |
| Water shop | Android tablet or PC, barcode scanner, 80mm thermal printer, cash drawer |
| Driver | Android phone (camera scanning, GPS), optional Bluetooth scanner and Bluetooth thermal printer |

No specialised expensive hardware is required. iPhone is supported through Safari with browser printing.

---

## D-6. UX REQUIREMENTS

Every important action has: validation, clear confirmation, loading state, success and error messages, empty states and permission-aware rendering. Destructive or reversing actions require confirmation and a **reason** for financial, stock and bottle changes. Keyboard-friendly data entry on desktop; scan-first flows on operational screens.

---

## D-7. RESPONSIVE DESIGN

Test at: 1920×1080, 1440×900, 1366×768 (desktop); 1024×768, 768×1024 (tablet); 390×844, 375×812 (mobile).

Mobile is not a shrunken desktop. Build dedicated mobile layouts for the driver app, shop POS, scanning, delivery confirmation, bottle collection and approvals.

---

## D-8. AI MANAGEMENT ASSISTANT (PHASE 4)

Read-only natural-language assistant for management, e.g. "What were today's sales?", "How many Aqua bottles are we holding?", "Which routes have the most failed deliveries this month?"

* Runs through a **read-only database role** against curated reporting views; it cannot call write RPCs.
* Respects the asking user's permissions and RLS.
* Shows the figures and the underlying filter/report link so answers can be verified.
* All questions and answers are logged.

---

# PART E — DELIVERY PLAN, DATA & ACCEPTANCE

## 43. DATABASE DESIGN

Normalised PostgreSQL schema with foreign keys, indexes, check constraints, `created_at/updated_at/created_by`, soft-delete (`archived_at`) for master data only. Ledgers are never deleted.

Minimum tables (expand as needed):

* **Identity & access:** users, roles, permissions, role_permissions, user_roles, devices
* **Master data:** customers, customer_addresses, products, product_units, price_lists, price_list_items, tax_codes, tax_rates, identifiers, locations, warehouses, bins
* **Bottles:** bottle_types, bottles, bottle_transactions, bottle_balances, external_companies, external_company_bottle_ledger, external_handovers, external_handover_items, bottle_policies, bottle_deposits, bottle_exceptions, label_batches
* **Sales & orders:** orders, order_items, recurring_orders, invoices, invoice_items, credit_notes, receipts, payments, payment_allocations, cash_sessions
* **Delivery:** routes, route_customers, vehicles, drivers, deliveries, delivery_items, delivery_proofs, route_runs (load-out/check-in), reconciliation_exceptions
* **Water shops:** water_shops, shop_users, shop_inventory, shop_stock_requests, shop_stock_request_items, shop_stock_transfers, shop_sales, shop_sale_items, shop_closings, shop_settlements
* **Inventory:** inventory_items, inventory_balances, inventory_transactions, stock_counts, stock_count_lines, lots
* **Production & QC:** production_batches, production_records, batch_materials, batch_bottles, qc_templates, qc_tests, qc_results, recalls
* **Procurement:** suppliers, purchase_requests, purchase_orders, purchase_order_items, goods_receipts, supplier_invoices
* **Finance:** accounts, journal_entries, journal_lines, posting_rules, accounting_periods, bank_accounts, bank_reconciliations, expenses
* **People:** employees, departments, positions, attendance, leave, payroll_runs, payroll_lines, sales_representatives, distributors
* **Other:** complaints, assets, asset_maintenance, documents, notifications, notification_templates, approvals, approval_rules, audit_logs, system_settings, document_sequences, sync_log

---

## 44. IMPLEMENTATION PHASES

The original single Phase 1 was too large and depended on accounting that was scheduled for Phase 2. The plan below fixes both problems.

### Phase 0 — Foundation

Project setup, design system and layout shell, auth, roles/permissions, RLS framework, audit trigger framework, document numbering, settings tables, identifiers/barcode service, label printing, minimal **posting-rules engine + general ledger tables** (no accounting UI yet), seed data.

**Done when:** a user can log in, sees only permitted navigation, every insert/update is audit-logged, labels can be generated and printed, and a test transaction posts a balanced journal entry.

### Phase 1A — Core bottle & delivery loop

Customers, products & price lists, warehouse inventory (finished goods and bottles), bottle management, external bottle intake and holding, bottle policies and deposits, orders, recurring orders, deliveries, routes, driver web app with camera scanning, load-out/check-in reconciliation, receipts, dashboard (operational KPIs), offline outbox for the driver app.

**Done when:** acceptance scenarios 1, 2, 3 and 7 pass.

### Phase 1B — Water shops & POS

Head-office POS, shop management, shop inventory, stock requests, shop POS, daily closing, settlements, thermal printing options, offline for POS.

**Done when:** scenario 4 passes.

### Phase 2 — Operations & finance

Production, QC (holds and recalls), procurement, suppliers, full accounting UI and reports, payments, expenses, tax, HR & payroll, fleet, assets.

**Done when:** scenarios 5 and 6 pass with full financial reports.

### Phase 3 — Commercial & control

Distributors, CRM, complaints, notifications (email/SMS/WhatsApp), documents, approval workflows UI, advanced reports.

### Phase 4 — Intelligence

AI management assistant, advanced analytics, demand forecasting, route optimisation.

---

## 45. REPORTING

Centralised reports with filters, drill-down and export.

* **Sales:** daily, monthly, by product, customer, shop, distributor, sales rep
* **Inventory:** current stock, movements, damaged, low stock, valuation, lot/expiry
* **Bottles:** OLA circulation, balances by customer/driver/shop, external held and returned by company, external company two-way statements, bottle value exposure, lost/damaged/written off, discrepancies, bottle ageing, fill-count/retirement due
* **Delivery:** success rate, failures by reason, driver performance, route performance, vehicle performance
* **Production & QC:** quantity, wastage, rejection, batch performance, QC failures, recalls
* **Finance:** P&L, balance sheet, cash flow, trial balance, receivables/payables ageing, expenses, shop balances, tax reports, deposit liability

---

## 46. DEMO DATA

Realistic Sri Lankan demo data (fictional, no real personal information):

* Customers across all types in Colombo, Gampaha, Kandy, Galle and Kurunegala, with `+94` phone numbers and realistic addresses
* Products: OLA 19L, 5L, 1.5L, 500ml with LKR prices
* External companies: Aqua Water, XYZ Water, ABC Water (fictional)
* 3 water shops, 2 warehouses, 4 routes, 4 vehicles, 6 drivers
* Bottles: a few thousand OLA bottles and a few hundred tagged external bottles spread across holders
* Some open exceptions, overdue invoices and pending approvals so every dashboard and alert has real data to show

---

## 47. ACCEPTANCE SCENARIOS

Each scenario must be automated as an integration test and also demonstrable by a non-technical employee in the UI.

1. **Normal sale:** create customer → order → pick → assign → load-out → deliver → collect payment → inventory, bottle balance, invoice, journal entry and audit trail all correct.
2. **OLA bottle return:** customer returns OLA bottle → scan → bottle status, customer balance, driver holding and (after check-in) warehouse updated.
3. **External bottle:** customer hands over an unlabelled Aqua bottle → intake with tag → policy applied → driver check-in → warehouse verification → external holding → hand-over to Aqua with signed note → complete history visible on the bottle record and on the Aqua statement.
4. **Water shop:** stock request → approval → picking → dispatch → shop receipt (with one short item creating an exception) → shop sale with scan → thermal receipt → bottle return → daily closing → settlement → journal entries.
5. **Production:** create batch → production with material consumption → QC hold → QC pass → available for sale. Also: QC fail → stock cannot be sold.
6. **Financial:** sale → invoice → partial payment → customer ageing → journal entries → trial balance balances → P&L reflects the sale.
7. **Audit:** an employee corrects a transaction via reversal → before/after and reason recorded → authorised manager views it; an unauthorised user cannot.
8. **Offline:** driver loses connection, completes three deliveries with bottle scans and cash, reconnects → all transactions sync once, no duplicates, any conflicts appear as exceptions.
9. **Driver discrepancy:** route check-in is one external bottle and Rs. 500 short → exception created → resolved with approval → audit trail shows the full chain.

---

## 48. DEVELOPMENT RULES

1. No fake functionality, dead buttons or placeholder dashboards pretending to show data.
2. Every important UI action is connected to the database through a server-side function.
3. Use real relationships and constraints.
4. Validate critical transactions server-side; run them in database transactions.
5. Enforce idempotency with `client_txn_id`.
6. Audit logging is automatic (triggers), never optional.
7. Never delete financial, inventory, bottle or audit records; reverse them.
8. Keep full bottle ownership and inventory movement history.
9. Keep business logic in one place (database functions + shared domain modules). No duplicated rules in the UI.
10. All rates, limits, thresholds and policies are configurable.
11. Clear error handling with user-friendly messages and logged technical detail.
12. Index for the actual queries used; check slow queries before each phase sign-off.
13. Build reusable components (data table, scan input, status badge, money input, approval dialog, reason dialog).
14. Write tests for every RPC that moves money, stock or bottles.
15. Record assumptions and decisions in `DECISIONS.md`.

---

## 49. FINAL REQUIREMENT

This is one integrated business system, not a set of separate modules.

A delivery sale must flow through:
**Customer → Order → Inventory → Bottle Ledger → Delivery → Payment → Invoice → Journal Entry → Reports → Audit Trail**

A water-shop sale must flow through:
**Shop → Shop Inventory → Sale → Bottle Ledger → Payment → Closing → Settlement → Journal Entry → Audit Trail**

An external bottle must be traceable from:
**Customer → Driver → Warehouse → External Holding → External Company Hand-over → Audit Trail**

For any transaction, management must be able to answer:

**What happened? Who did it? When? Where? What changed? What was the financial impact? What happened to the bottle, product or stock? Who approved it?**

The result must be a professional, scalable, secure and production-ready **OLA Water ERP for Sri Lanka**, delivered entirely through responsive web applications.

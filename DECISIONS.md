# Decisions log

Assumptions and decisions made while building, as required by the master prompt (§ How to use this document, rule 5). Newest phase first.

## Phase 4 — Analytics, planning and route ordering (October 2026)

**D-4-01 · No AI assistant and no paid map service (owner's decision).** The AI management assistant (master prompt D-8) is not built; the reports centre and analytics answer the same questions. Routes are ordered from the GPS points already stored — no Google Maps or other routing service and no API keys. The map uses free OpenStreetMap tiles (with the required attribution); if the office ever has very heavy map use, a paid tile provider can be swapped in.

**D-4-02 · Route ordering** = nearest stop first from the start, then improved by swapping legs until no shorter order is found ("2-opt"). Distances are straight-line between GPS points × `planning.road_factor` (1.3) to estimate road km — good for ordering stops, not exact driving distance (no one-way streets or traffic). A run starts at the warehouse (and returns) or, once on the road, from the last completed stop. Stops without GPS are kept at the end. Re-ordering a run changes only pending stops; a route's order sets each customer's route sequence, which new runs use. The warehouse location is set on the Planning page.

**D-4-03 · Demand forecast** per product: the last 12 weeks of units sold, the last 4 weeks counting double, never less than what active recurring orders need each week. Suggested production = forecast for the chosen weeks + safety stock (`planning.safety_stock_days`, 2 days) − available stock − stock on QC hold. Materials to buy = (suggested production × bill of materials) + reorder level − in stock − on open purchase orders. This is a planning aid; production and purchasing still decide.

**D-4-04 · Customers due for a refill**: at least 3 orders in the last 6 months, the median gap between their orders, next order due within `planning.refill_window_days` (2), nothing on order, not on a recurring order, not more than 30 days overdue (those are in "Customers who stopped buying"). The dashboard shows how many are due today.

**D-4-05 · Analytics** charts (Recharts) show 6, 12 or 24 months: sales against a year earlier, collections and expenses, 19L units and customers served, delivery success, complaints, and sales by customer type, product, route and top customers.

### Not verified in this phase
- Ordering, forecast, materials, refill and analytics were tested against PostgreSQL 16 (stops along a road put in order, km saved, the new order applied, a weekly customer flagged as due). Screens were type-checked and production-built but not clicked through against the live project. Map tiles need internet on the viewing device.

## Phase 3C — Reports (October 2026)

**D-3C-01 · One reports centre.** 39 operational reports (sales, customers, stock, bottles, delivery, production & QC, finance, complaints) come from one database function, `run_report`, so the screen, the print-out and the Excel download always show the same figures. They are calculated from the live records each time (no overnight copies). The accounting reports from Phase 2B, fleet profitability, commissions, EPF/ETF and the asset register are linked from the same page.

**D-3C-02 · Who sees which reports** follows the module permissions: sales and customer reports — Reports or Accounting (or sales team managers); stock — Inventory; bottles — Bottles; delivery — Deliveries; production — Production or QC; finance — Accounting; complaints — Complaints. Downloading needs `reports.export`, and **every download (including the accounting CSVs) is written to the audit trail** with its filters.

**D-3C-03 · Definitions.** Sales are invoices (not void) by invoice date: "before VAT" = net of discounts; credit notes are not deducted in the sales reports (they are in the P&L). Rep and distributor sales are the invoices of the customers assigned to them; a distributor's target is pro-rated to the period. Delivery success = delivered + part delivered ÷ (those + failed). Production yield = produced ÷ planned; rejection = rejected ÷ (produced + rejected). Bottle exposure = OLA bottles outside the warehouse × replacement value, less deposits held for bottles with customers. Bottle ageing counts labelled bottles by days since they last moved. A bottle is "due for retirement" at 90% of `bottles.max_fill_count` (default 50 — confirm with your bottle supplier) or when not in good condition.

**D-3C-04 · Limits.** A period can be at most 3 years; long lists stop at 1,000–3,000 rows (use filters or the download). PDF is through the browser's Print → Save as PDF.

### Not verified in this phase
- Every report was run against PostgreSQL 16 with the test data, checked against the source tables (daily sales and channels = invoices, stock valuation = balances, bottle circulation = all OLA bottles) and against the columns the screens show. Screens were type-checked and production-built but not clicked through against the live project.

## Phase 3B — Sales team, distributors, CRM (October 2026)

**D-3B-01 · Sales reps** are staff logins (optionally linked to an employee) with a code, territory and commission plan. Customers are owned by a rep (Sales Team → assign customers). Monthly targets: sales (before VAT), collections, new customers and visits; actuals come from the rep's own customers' invoices and payments.

**D-3B-02 · Visits** are checked in / out from the phone with GPS. A check-in further than `sales.visit_radius_m` (300 m) from the customer's saved location is accepted but flagged. One open visit at a time.

**D-3B-03 · Collections by reps.** Cash collected by a rep posts Dr Cash with Sales Reps (1150) / Cr Receivable and stays "with the rep" until handed in (to a cash or bank account, in part or in full); cheques need the cheque number. Reps holding cash for more than a day raise an alert.

**D-3B-04 · Commissions** = sales × sales rate + collections × collection rate + (target met: sales × bonus rate) + new customers × bonus (plans editable; the seeded plan is an example). Statements are prepared for a month that has ended, can be adjusted with a reason, and are approved by someone with commission rights other than the rep (Dr Sales Commissions 6215 / Cr Commissions Payable 2520). Reps who are employees are paid on their next payroll (the payslip clears the payable); others are paid directly.

**D-3B-05 · Distributors / dealers** sit on top of a customer account — price list, credit limit, orders, invoices, payments and bottles stay on the customer, so nothing is duplicated. The profile adds territory, agreement dates (alert 30 days before it ends), monthly target, agreed minimum stock and the stock they report holding.

**D-3B-06 · CRM.** Leads (new → contacted → prospect → offer → customer / lost, lost needs a reason) with follow-ups and activities, opportunities with stage and probability, and conversion: "win" creates the customer (credit terms through approval as usual) and keeps the link so conversion and first sale can be reported. Existing customers' phone numbers are not accepted as leads.

**D-3B-07 · Segments** are saved filters (customer type, route, rep, bottle model, city, days since last order, overdue, created after, monthly sales). **Campaigns** record channel, budget and dates, and can send an SMS / WhatsApp to a segment through the Phase 3A outbox (once per customer per campaign, capped by `crm.max_campaign_messages`; opted-out customers are skipped).

**D-3B-08 · Promotions** (% off, Rs. off per unit, special price, buy X get Y) for chosen products, customer types, segment or price list, with dates and a minimum quantity. Switching one on is a price change and goes through the Approvals rule "Promotion switched on" (price approver). The best active promotion is applied automatically to delivery orders on top of any manual discount and needs no further discount approval. Promotions are not applied at the shop / head-office POS.

### Not verified in this phase
- All flows were tested against PostgreSQL 16 (targets, GPS distance, collections and hand-in, commission → payroll → ledger, distributors, lead to customer conversion, segments, promotions with approval on orders, campaign messages, ledger balanced). Screens were type-checked and production-built but not clicked through against the live project. GPS accuracy depends on the phone.
- **Agree the commission plan figures with management** before the first month is prepared.

## Phase 3A — Approvals, notifications, complaints, documents (October 2026)

**D-3A-01 · Phase 3 split.** 3A (control: approvals inbox and rules, notifications and customer messages, complaints, documents), 3B (distributors, sales representatives, CRM), 3C (reports centre).

**D-3A-02 · Approvals instead of refusals.** Large stock adjustments, discounts above the limit, credit limit / payment-term changes (including new credit customers), price list changes and bottle write-offs used to be refused for people without the right permission. Now the action is test-run (to catch ordinary mistakes immediately), stored as an approval request and carried out **for the person who asked** when the last approver approves; the audit trail shows the requester as the actor and "approved by … (APR-…)" as the reason. Nobody approves their own request. Each rule's approver permission, number of approvers (1–3, different people) and on/off switch is set in Approvals → Rules; limits are the existing approval settings. With two or three levels even approvers must ask.

**D-3A-03 · What an approval carries out.** A stock count is applied as counted at approval time (if stock moved in between, the difference is recalculated). An order with a large discount is created only when approved. Credit terms change only the two credit fields (never other details edited since); a new credit customer is created at once on cash terms. A price change takes effect on its date, or on the approval date if that has passed.

**D-3A-04 · Module approvals stay in their modules** (expenses, purchases, mismatched supplier invoices, manual journals, payroll, leave, orders on credit hold, shop stock requests, QC release) but all appear in the one approvals inbox, and the rules page shows who can approve each.

**D-3A-05 · Notifications** are in-app (the bell) for staff, routed by permission and configurable in Messages & Alerts (also optionally emailed). Event alerts (approval needed/decided, complaint assigned, quality complaint) are immediate; the others come from a scan that runs at most every 10 minutes while staff use the system, and every morning from Vercel Cron: low stock, overdue balances, failed deliveries, vehicle service and documents, document expiry, external bottles above the alert level, overdue complaints, batches on QC hold, items waiting for approval (one reminder a day each), failed messages. "Unsynced offline data" is still shown on the Dispatch and Exceptions screens rather than as an alert (the server cannot see what is stuck on a phone).

**D-3A-06 · Customer messages** (English) go by SMS by default — order confirmed, delivered (with balance), delivery missed, payment received (not for payments taken at a delivery, already in the delivered message), payment reminder (when the oldest unpaid invoice is 7 days overdue, repeated every 7 days), complaint received / resolved. Nothing is sent until "Customer messages" is switched on and a provider is configured. Customers can be opted out. Every message is logged (queued → sent / failed, retried up to 3 times). WhatsApp business-initiated messages need templates approved by Meta; set the template name on each message.

**D-3A-07 · Provider keys live only in Vercel environment variables**, never in the database: SMS via Notify.lk, Text.lk or any HTTP webhook; WhatsApp Cloud API; email via Resend. Messages are sent from the app server (after page loads, at most every 2 minutes, and daily by Vercel Cron at 08:30 Sri Lanka time — the free Vercel plan allows one cron a day).

**D-3A-08 · Complaints** follow New → Assigned → In progress → Resolved → Closed (reopen allowed). Due time = logged time + hours by priority (urgent 4, high 24, normal 48, low 72 — settings). Product and quality complaints that name a batch require a QC finding before they can be resolved; QC uses its normal tools (re-test, hold, recall). The timeline is append-only. Photos are stored privately.

**D-3A-09 · Documents** are stored in a private bucket by type; who can see/upload each type follows a permission (employee papers → HR, vehicle → fleet, lab reports → QC, contracts/licences/insurance → documents). Licences and insurance require an expiry date. A renewed document is uploaded as a new version; old versions and archived documents are kept. Vehicle insurance/licence/emission dates from Fleet are included in the expiry list.

### Not verified in this phase
- All approval, notification, messaging, complaint and document flows were tested against PostgreSQL 16 (including two-level approvals, rejection, test-run validation, opt-out, retry, QC review and document permissions). The SMS / WhatsApp / email calls were not sent to real providers — send a test message to your own phone after setting up the provider.
- Screens were type-checked and production-built but not clicked through against the live project.

## Phase 2C — People, fleet & assets (October 2026)

**D-2C-01 · Statutory rates are effective-dated data, not code.** EPF (employee 8%, employer 12%), ETF (3%) and the monthly APIT table are stored with a start date and can be changed in Payroll → Statutory settings without a software update. The seeded APIT table (from 1 April 2025: first Rs. 150,000 a month tax-free, then 6/18/24/30/36%) is a starting point — **your accountant must confirm it, and the EPF/ETF rates, before the first real payroll**. APIT is calculated on gross pay less non-taxable allowances; EPF/ETF on basic salary less no-pay plus allowances marked "EPF liable".

**D-2C-02 · Payroll formulas and settings.** No-pay deduction = basic ÷ `payroll.nopay_divisor` (30) × no-pay days. Overtime = basic ÷ `payroll.ot_divisor` (240) × `payroll.ot_multiplier` (1.5) × hours. Daily-paid workers are paid daily rate × days present (half day = 0.5) plus overtime. All three settings can be changed in System Settings.

**D-2C-03 · Payroll needs two people.** One person (`payroll.run`) prepares the month; a different person with `payroll.approve` approves it (a Super Admin may approve their own, for single-person setups — audited). Approval posts the salary journal (Dr Salaries, Dr EPF/ETF expense / Cr Salaries payable, EPF payable, ETF payable, APIT payable, staff advances, other deductions) and locks that month's attendance. Salary payment is a separate step (`payments.manage`) from a bank or cash account. EPF/ETF/APIT are paid to the authorities from the statutory screen.

**D-2C-04 · Leave** counts working days only — Sundays and the public holidays entered in Attendance are skipped. Entitlements come from the leave type (Annual 14, Casual 7, Medical 7, Maternity 84 by default — edit to match your policy); no-pay leave reduces pay. Approved leave fills attendance automatically.

**D-2C-05 · Salary advances** are paid from cash/bank (Dr Staff advances) and recovered from the following payrolls in the instalment chosen; the outstanding balance is shown on the employee.

**D-2C-06 · Postings into closed months.** If a payroll, depreciation run or asset registration belongs to an accounting month that is already closed, the entry is posted on today's date instead (in the open month) with the original month in its description, so closed months stay closed.

**D-2C-07 · Depreciation** runs monthly, in order (no month can be skipped, none in the future, each month once): straight line = (cost − residual) ÷ useful life in months; reducing balance = book value × rate ÷ 12. It stops at the residual value. Assets bought before go-live are entered with "depreciation to date" so the ledger starts correctly (Dr Asset / Cr Accumulated depreciation, Cr Opening balance equity).

**D-2C-08 · Disposal** posts the gain or loss against book value (4920 Gain / 6410 Loss on disposal). Run depreciation up to the disposal month first.

**D-2C-09 · Fleet costs are expenses.** Fuel, services, repairs, insurance, revenue licences and emission tests are recorded as expenses linked to the vehicle (and to the run when the driver paid), so they go through the same approval limits and appear in vehicle profitability. Alerts fire `fleet.document_alert_days` (30) days before a document expires and `fleet.service_alert_km` (500 km) before a service is due.

**D-2C-10 · Driver road expenses.** A driver can record fuel, tolls & parking, a repair or vehicle documents on the phone (offline, with a bill photo), only while the run is on the road and only up to the cash carried. They are paid from the driver's cash (Cr Driver cash), so the cash expected at check-in is reduced. Small amounts post at once; above the expense approval limit they wait for approval. **If the office rejects a driver expense, the amount becomes a cash shortage exception for that driver.**

**D-2C-11 · Vehicle profitability** = sales delivered by that vehicle (before VAT) − fuel − repairs/services − other vehicle costs − depreciation. Driver wages are not allocated to vehicles.

### Not verified in this phase
- All payroll, leave, advance, statutory, asset, depreciation, disposal, fleet and driver-expense flows were tested against PostgreSQL 16 (including a full September payroll with no-pay, OT, EPF/ETF/APIT and advance recovery checked by hand, and the ledger balancing after every flow). Screens were type-checked and production-built but not clicked through against the live project.
- **Ask your accountant** to confirm the APIT table, EPF/ETF rates, the treatment of each allowance (EPF liable / taxable), and the depreciation rates per asset category before the first real payroll and month-end.

## Phase 2B — Finance (October 2026)

**D-2B-01 · Money accounts.** Cash in hand, petty cash, each bank account and card/QR clearing are "money accounts", each tied to one ledger account. A new bank account automatically gets the next free code (1201…1209). Automatic postings from sales and purchases still use the default accounts; transfers, expenses, cheque deposits, reconciliations and VAT payments let the user choose the account.

**D-2B-02 · Manual journals need two people.** They are submitted with a reason and posted only when a different user with `accounting.manual_journal` approves them (a Super Admin may approve their own, for single-person setups — audited). Direct posting (`post_manual_journal`) is kept only for finance managers (`accounting.period_close`).

**D-2B-03 · Reports read the ledger.** Every report is calculated from journal lines at the moment it is opened, so it is always current and always agrees with the trial balance. Balance sheet: income and expense accounts are not closed to retained earnings by a year-end entry; the report shows "profit of earlier years" and "profit this financial year" instead. The financial year starts in April (setting `accounting.fiscal_year_start_month`).

**D-2B-04 · Cash flow** uses the direct method: every entry that changes cash, bank, driver cash, shop cash or cheques in hand is classified by the other side of the entry (customers, suppliers, expenses, salaries, taxes, fixed assets, owners). Transfers between cash accounts cancel out.

**D-2B-05 · Ageing** is based on each open invoice's due date against the chosen date, using today's unpaid balances. Unused payments and credit notes are shown separately as unused credit.

**D-2B-06 · Cheques.** A cheque payment starts "in hand" (Dr Cheques in Hand). Depositing posts Dr Bank / Cr Cheques in Hand. A returned cheque posts Dr Receivable / Cr the bank (or Cheques in Hand if never banked), marks the payment reversed and adds negative allocations so the invoices become unpaid again — allocations remain append-only. Bank charges for a returned cheque are recorded as a bank charge; recharging them to the customer is not automated.

**D-2B-07 · Payment reversal** posts the exact opposite of the payment's journal (today, in an open month) and needs both `payments.manage` and `accounting.reverse`. A banked cheque is handled as a returned cheque instead.

**D-2B-08 · Credit notes** are their own documents (CN numbers): Dr Sales Returns & Allowances (4160), Dr VAT Output / Cr Receivable. They are applied to the chosen invoice, then to the oldest unpaid invoices; anything left is the customer's unused credit, applied later with "Apply unused credit". They need `payments.manage` plus `customers.credit` or `accounting.manual_journal`. Credit notes do not move stock.

**D-2B-09 · Bank reconciliation** ticks ledger lines against the statement; it can be saved only when ticked items plus earlier reconciled items equal the statement balance exactly. Reconciled items cannot be reconciled again; reconciliations are append-only.

**D-2B-10 · Expenses** below `approvals.expense_amount` (Rs. 25,000), or entered by someone with `expenses.approve`, post immediately; others wait for an approver who is not the person who entered them. "Not paid yet" expenses post to Expenses Payable (2150) and are paid later. Driver fuel and route expenses: see D-2C-10.

**D-2B-11 · VAT returns** clear everything in VAT Output and VAT Input up to the end of the return period: output is netted against input, the difference is paid from the chosen bank; excess input VAT stays as a credit carried forward. Returns cannot overlap and can be filed only for periods that have ended. SSCL is not calculated automatically yet.

### Not verified in this phase
- All flows were tested against PostgreSQL 16 (scenario 6, cheques, reversals, credit notes, journal approval, transfers, reconciliation, expenses, VAT return, report consistency: trial balance = 0, assets = liabilities + equity, cash-flow opening + movement = closing, ledger = trial balance). Screens were type-checked and production-built but not clicked through against the live project.
- **Ask your accountant** to review the chart of accounts, the VAT treatment and the financial-year setting before relying on the reports.

## Phase 2A — Production, QC & purchasing (October 2026)

**D-2A-01 · Phase 2 is delivered in three parts** (2A production/QC/purchasing, 2B finance, 2C people & assets) so each part can be tested in the live system before the next.

**D-2A-02 · Materials are items in the same table as products** (`products.item_type`), so they share the stock ledger, counts, transfers and valuation. Only `finished_good` items can be sold — enforced in the stock ledger itself (`app.stock_move` refuses a sale of a material) and tills/order screens only list finished goods.

**D-2A-03 · Stock statuses.** `available`, `qc_hold`, `quarantine`, `damaged`. Every pick, load-out, transfer and sale takes only `available`, so stock on hold or in quarantine cannot leave by any route.

**D-2A-04 · Batch (lot) tracking on every movement.** `inventory_lots` splits each balance by production batch; movements take the oldest batch first (FIFO) unless a batch is named, and each ledger row records its batch. Stock that existed before go-live has no batch. A test proves lots always add up to the balances. Shop tills selling more than their recorded stock (allowed offline, see D-1B-08) create unbatched stock that is flagged as an exception.

**D-2A-05 · Water enters stock only through a production batch** (setting `production.allow_manual_receipt`, off). A user who may release QC batches (`qc.release`) can still record a manual fill as an exception; opening stock at go-live is still allowed.

**D-2A-06 · Release rules.** A QC officer (`qc.manage`) can release a batch whose latest test passed. Anything else (no test, failed test, failed batch) needs `qc.release` plus a reason, and is recorded as `qc_override_release` in the audit trail. QC tests and results are append-only; each result keeps a copy of the limits used.

**D-2A-07 · Recalls.** Stock at warehouses and shops is quarantined immediately; stock on vehicles is listed for the driver to bring back and is caught by "Secure stock again". Customers are identified from deliveries and till sales of the batch and from traced bottles they hold. Units collected from customers return to quarantine; credit notes for them come with Phase 2B.

**D-2A-08 · Costing.** Weighted average cost, updated by goods received (order price before VAT) and by production (materials used ÷ good units). Rejected units' materials are absorbed into the good units' cost; if nothing good is produced the materials go to Production Losses. Average cost can only be typed in by hand while an item has no stock.

**D-2A-09 · Purchase accounting.** Goods received: Dr Inventory / Cr Goods Received Not Invoiced (GRNI, 2110). Supplier invoice: Dr GRNI at order price, the difference to Purchase Price Variance (5200), Dr VAT Input / Cr Accounts Payable. Payment: Dr AP / Cr Bank or Cash. GRNI returns to zero once everything received is invoiced. Cheque lifecycle (issued/cleared) comes with Phase 2B.

**D-2A-10 · 3-way match tolerance.** An invoice line matches when its quantity is within what was received and not yet billed, its price is within `procurement.price_tolerance_percent` (2%) of the order price and its VAT rate equals the order's. Otherwise the whole invoice is held for `procurement.approve`; a rejected invoice is voided and its quantities released. Purchase orders below `approvals.purchase_amount` (Rs. 100,000) are approved on creation.

**D-2A-11 · Not in 2A:** bin locations inside a warehouse, supplier lot traceability through production (supplier lot and expiry are recorded on goods received only), purchase returns after acceptance, and non-stock purchases (services go through Expenses in 2B).

### Not verified in this phase
- All flows above were tested against PostgreSQL 16 (scenario 5 pass and fail, full purchase cycle, recall, FIFO, costing, ledger balance), and the screens were type-checked and production-built, but not clicked through against the live Supabase project — use the first-time checks in the guide.
- QC certificate upload needs the storage bucket created by the update (it is skipped if Supabase storage is unavailable).

## Phase 1B — Water shops & POS (October 2026)

**D-1B-01 · Two shop models, chosen per shop.** *Company-owned*: stock and sales belong to OLA (OLA invoices, VAT and journals; takings banked on settlement; commission accrued to `2510 Shop Commissions Payable` / `6210 Shop Commissions`). *Dealer*: stock is invoiced to the dealer's account at the **transfer price list** when the dealer confirms receipt; the dealer's own till sales create no OLA invoice or journal (`p_post = false`) but stock and bottles are still tracked so OLA knows what is at every shop. Receipts at dealer shops carry the dealer's name, not OLA's VAT number.

**D-1B-02 · Location-limited roles.** A role assignment limited to a location now only grants rights at that location: `app.has_permission()` answers for unlimited grants only, `app.has_permission_at(code, location)` for a specific place. Shop staff therefore see only their own shop (RLS and every shop RPC check the location). Menu items marked "anywhere" appear when the user has the right at any location.

**D-1B-03 · One selling engine.** The pricing, VAT, deposit, bottle and stock logic used by the driver's delivery was moved into `app.sale_core` and is now shared by deliveries and the till, so a bottle or deposit rule behaves the same everywhere. All Phase 1A tests pass unchanged on top of it.

**D-1B-04 · Walk-in customers.** Each shop/counter has one pooled walk-in customer. Walk-in bottle deposits are held against that pool, so a walk-in can return a bottle bought at the same shop and get the deposit back. Walk-ins are hidden from the customer list.

**D-1B-05 · Stock in transit.** Dispatched shop stock moves to a system location `TRN` (In Transit) until the shop counts it in, so nothing is "nowhere" between warehouse and shop.

**D-1B-06 · Offline receipt numbers** (spec D-4.5). Each till session has a unique prefix (`R` + location code + year + session, e.g. `RSH01-260007`); the device numbers receipts within it (`RSH01-260007-0012`). No two devices can produce the same number and no central call is needed to sell.

**D-1B-07 · One open till per location.** Opening and closing need internet; selling does not. A till cannot be closed while sales from it are still waiting on the device.

**D-1B-08 · Tills never refuse a sale for business reasons after the fact.** A sale made offline that breaks a rule when it syncs (credit limit, discount limit, short stock) is still recorded — the money and bottles really changed hands — and the problem is raised as a flag/exception for a manager. Only invalid data (unknown product, closed till) is refused.

**D-1B-09 · Refunds are real payments out.** `payments.direction = 'out'` records deposit refunds paid in cash; customer balances are net of refunds.

**D-1B-10 · Exceptions are generalised.** Exceptions now also cover shops, transit and tills (`target_location_id` = where missing items should have gone). Resolving "found" on a transfer shortage moves the goods to the shop (and invoices a dealer for them).

### Not verified in this phase
- All database flows were tested on PostgreSQL 16 (company-owned shop full day, dealer shop, head-office counter, location limits, offline replay). Screens were type-checked and production-built but not clicked through against the live Supabase project — do the first-time checks in the guide.
- Print the shop statement and a till receipt on the real printers before go-live.

## Phase 1A — Core bottle & delivery loop (October 2026)

**D-101 · Two ledgers.** Filled product stock (`inventory_*`) and returnable containers (`bottle_*`) are separate ledgers. Moving a returnable product (e.g. 19L) automatically moves the same number of full OLA bottles in count mode.

**D-102 · Serialised and counted bottles together.** Balances always count every bottle; tagged bottles additionally have their own record and history. When a tagged bottle is scanned somewhere other than where its record says, the scan is accepted, counts follow the physical event, the record is corrected and a `bottle_location` exception is raised (info if the record pointed at an OLA location, warning if at another customer).

**D-103 · Never block the driver.** A label printed but not yet registered is registered at the door; an unknown label is counted and flagged; an `EXT-` tag scanned among OLA bottles is treated as that company's bottle (company from the tag prefix). Only physically impossible actions are refused (delivering more than is on the vehicle).

**D-104 · External bottle policy** resolves customer → company → system default (`accept_one_for_one`, as chosen by OLA). Under one-for-one, the customer's OLA bottle count drops by one and the replaced OLA bottle is recorded as gone (to "outside"), so exposure reports show it.

**D-105 · Deposits** (deposit-model customers) are re-balanced on every delivery: deposits held always equal the OLA bottles the customer holds; extra bottles add a deposit line, returned bottles refund it on the invoice. Deposits are a liability (2200), never revenue. Customers' bottles held before go-live are entered as opening balances (without deposit history).

**D-106 · Bottle model defaults** follow OLA's answer: households pay a deposit; businesses borrow up to a limit (office 10, restaurant 10, shop 10, hotel 20, supermarket 20, institution 20, corporate 20, distributor 50, water shop 50). All are placeholders, editable in Products & Prices → Customer type defaults.

**D-107 · Holds instead of approvals.** Until the approval workflow (Phase 3), orders that breach credit limit, overdue balance or bottle limit go **on hold** and need someone with `customers.credit` to release them, with a reason. Discounts above the setting need `pos.discount`.

**D-108 · Prices include VAT by default** (Sri Lankan retail style); VAT is extracted from the line total. Each price list can be switched to VAT-exclusive. VAT and other rates are effective-dated and must be set by management — no rate is seeded. SSCL is not yet calculated on invoices; **ask your accountant** how OLA applies SSCL and it will be added as a tax component.

**D-109 · Invoices on delivery.** Every completed delivery creates an invoice (tax invoice when the customer has a VAT number), posts it to the ledger, applies any credit on account, then the payment. Invoice numbers are assigned when the delivery reaches the server (gapless); a receipt printed offline shows "NOT YET SYNCED" and no number.

**D-110 · Check-in is the control point.** The warehouse counts products, empties per company and cash; every difference becomes an exception. A run closes only when all differences are resolved (found / charge driver / write off / acknowledge). Cash shortages charged to the driver stay in "Driver Cash in Transit" (1120) until HR deductions exist (Phase 2).

**D-111 · Driver app offline design.** Single-page app at `/driver`; run data cached in IndexedDB; transactions queued in an outbox with a client-generated id and replayed through the same database functions (idempotent). Business errors are shown to the driver and never dropped. A service worker keeps the app shell available offline. OTP confirmation needs an SMS provider and arrives with Notifications (Phase 3); signature and photo are available now.

**D-112 · Photos** are compressed on the phone (≈1024 px JPEG) and stored in a private storage bucket `delivery-proofs`; signatures are stored with the delivery (small JPEG).

**D-113 · Cost of sales** posts at product cost price on delivery when a cost is set. Production costing replaces this in Phase 2.

**D-114 · Opening balances.** Go-live counts are entered as opening stock (Inventory → Receive → Opening), opening bottles at locations and customers (Bottles / Customer pages). Opening stock posts to Opening Balance Equity.

**D-115 · Demo data** (`supabase/seed.sql`) is only for a separate test project; it is never part of the live update files.

### Not verified in this phase
- As in Phase 0, screens are type-checked and built, and all database behaviour is tested (including upgrading a database set up with the Phase 0 file), but the app has not been clicked through against the live Supabase project yet.
- Camera scanning and Bluetooth printing must be tried on OLA's actual phones and printer.

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

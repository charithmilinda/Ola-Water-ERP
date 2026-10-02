// Operational reports (Phase 3C). Rows come from the database function
// run_report(slug, filters); this file only describes how to show them.

export type ColKind = "text" | "money" | "qty" | "int" | "pct" | "date" | "datetime";
export type Row = Record<string, unknown>;
export type Col = { key: string; label: string; kind?: ColKind; total?: boolean; href?: (r: Row) => string | null };
export type Filter = "period" | "location" | "customer_type" | "product" | "company" | "company_required" | "route" | "days" | "expiry_days";
export type ReportGroup = "Sales" | "Customers" | "Stock" | "Bottles" | "Delivery" | "Production & QC" | "Finance" | "Complaints";
export type ReportDef = {
  slug: string; group: ReportGroup; title: string; description: string; filters: Filter[]; columns: Col[];
  chart?: { label: string; value: string };
};

/** Same rule as app.report_allowed in the database. */
export const GROUP_PERMISSIONS: Record<ReportGroup, string[]> = {
  Sales: ["reports.view", "accounting.view", "sales_reps.manage"],
  Customers: ["reports.view", "customers.view"],
  Stock: ["inventory.view"],
  Bottles: ["bottles.view"],
  Delivery: ["deliveries.view", "deliveries.manage"],
  "Production & QC": ["production.view", "qc.view"],
  Finance: ["accounting.view"],
  Complaints: ["complaints.view", "complaints.manage"],
};

const customer = (r: Row) => (r.customer_id ? `/customers/${r.customer_id}` : null);
const m = (key: string, label: string, total = true): Col => ({ key, label, kind: "money", total });
const n = (key: string, label: string, total = true): Col => ({ key, label, kind: "int", total });
const q = (key: string, label: string, total = true): Col => ({ key, label, kind: "qty", total });
const pct = (key: string, label: string): Col => ({ key, label, kind: "pct" });
const t = (key: string, label: string): Col => ({ key, label });
const d = (key: string, label: string): Col => ({ key, label, kind: "date" });

export const REPORT_CATALOG: ReportDef[] = [
  // Sales
  { slug: "sales-daily", group: "Sales", title: "Daily sales", description: "Invoices, value and cash collected for each day", filters: ["period"],
    columns: [d("date", "Date"), n("invoices", "Invoices"), m("net", "Before VAT"), m("vat", "VAT"), m("total", "Total"), m("collected", "Collected")],
    chart: { label: "date", value: "net" } },
  { slug: "sales-monthly", group: "Sales", title: "Monthly sales", description: "Month by month, with customers served and cash collected", filters: ["period"],
    columns: [t("month", "Month"), n("invoices", "Invoices"), n("customers", "Customers", false), m("net", "Before VAT"), m("vat", "VAT"), m("total", "Total"), m("collected", "Collected")],
    chart: { label: "month", value: "net" } },
  { slug: "sales-by-product", group: "Sales", title: "Sales by product", description: "Quantity and value of each product sold", filters: ["period", "customer_type", "location"],
    columns: [t("product", "Product"), t("sku", "SKU"), q("qty", "Qty"), m("avg_price", "Avg. price", false), m("net", "Before VAT"), m("vat", "VAT"), m("total", "Total"), pct("share_pct", "Share")] },
  { slug: "sales-by-customer", group: "Sales", title: "Sales by customer", description: "Who bought the most, with what they owe now", filters: ["period", "customer_type", "route"],
    columns: [{ key: "customer", label: "Customer", href: customer }, t("customer_no", "No."), t("customer_type", "Type"), n("invoices", "Invoices"), m("net", "Before VAT"),
      m("total", "Total"), d("last_invoice", "Last invoice"), m("outstanding", "Owes now")] },
  { slug: "sales-by-customer-type", group: "Sales", title: "Sales by customer type", description: "Households, offices, hotels, shops …", filters: ["period"],
    columns: [t("customer_type", "Customer type"), n("customers", "Customers"), n("invoices", "Invoices"), m("net", "Before VAT"), m("total", "Total"), pct("share_pct", "Share")] },
  { slug: "sales-by-channel", group: "Sales", title: "Sales by shop & channel", description: "Delivery, each water shop and the counter", filters: ["period"],
    columns: [t("channel", "Channel"), n("invoices", "Invoices"), n("customers", "Customers", false), m("net", "Before VAT"), m("vat", "VAT"), m("total", "Total"), pct("share_pct", "Share")] },
  { slug: "sales-by-distributor", group: "Sales", title: "Sales by distributor", description: "Each distributor against target, and what they owe", filters: ["period"],
    columns: [{ key: "distributor", label: "Distributor", href: (r) => `/distributors/${r.distributor_id}` }, t("code", "Code"), t("territory", "Territory"),
      n("invoices", "Invoices"), m("net", "Before VAT"), m("target", "Target"), pct("target_pct", "Of target"), m("outstanding", "Owes now")] },
  { slug: "sales-by-rep", group: "Sales", title: "Sales by sales rep", description: "Sales of each rep's customers, collections, visits and target", filters: ["period"],
    columns: [{ key: "rep", label: "Rep", href: (r) => `/sales/reps/${r.rep_id}` }, t("code", "Code"), t("territory", "Territory"), n("customers", "Customers"),
      m("net", "Sales before VAT"), m("target", "Target"), pct("target_pct", "Of target"), m("collections", "Collections"), n("visits", "Visits")] },

  // Customers
  { slug: "customers-inactive", group: "Customers", title: "Customers who stopped buying", description: "Active customers with no invoice for a number of days", filters: ["days", "customer_type", "route"],
    columns: [{ key: "customer", label: "Customer", href: customer }, t("customer_no", "No."), t("customer_type", "Type"), t("phone", "Phone"), t("route", "Route"),
      t("rep", "Rep"), d("last_invoice", "Last invoice"), n("days_since", "Days", false), m("outstanding", "Owes")] },
  { slug: "customers-new", group: "Customers", title: "New customers", description: "Customers added in the period and whether they have bought", filters: ["period", "customer_type"],
    columns: [{ key: "customer", label: "Customer", href: customer }, t("customer_no", "No."), t("customer_type", "Type"), d("created", "Added"), t("rep", "Rep"),
      d("first_sale", "First sale"), m("net_to_date", "Sales to date")] },

  // Stock
  { slug: "stock-current", group: "Stock", title: "Current stock", description: "Every item at every location, by status, with value", filters: ["location", "product"],
    columns: [t("location", "Location"), t("product", "Item"), t("sku", "SKU"), t("stock_status", "Status"), q("qty", "Qty"), m("unit_cost", "Unit cost", false), m("value", "Value")] },
  { slug: "stock-valuation", group: "Stock", title: "Stock valuation", description: "Quantity and value of each item (weighted average cost)", filters: ["location"],
    columns: [t("product", "Item"), t("sku", "SKU"), t("item_type", "Kind"), q("available", "Available"), q("other", "Held / damaged"), q("qty", "Total qty"),
      m("unit_cost", "Unit cost", false), m("value", "Value")] },
  { slug: "stock-movements", group: "Stock", title: "Stock movements", description: "Every receipt, transfer, sale, production and adjustment", filters: ["period", "location", "product"],
    columns: [{ key: "at", label: "When", kind: "datetime" }, t("txn_type", "Movement"), t("product", "Item"), q("qty", "Qty", false), t("from_location", "From"),
      t("to_location", "To"), t("reason", "Reason"), t("by", "By")] },
  { slug: "stock-damaged", group: "Stock", title: "Damaged, held & quarantined", description: "Stock that cannot be sold", filters: ["location"],
    columns: [t("location", "Location"), t("product", "Item"), t("stock_status", "Status"), q("qty", "Qty"), m("value", "Value")] },
  { slug: "stock-low", group: "Stock", title: "Low stock", description: "Items at or below their reorder level", filters: ["location"],
    columns: [t("product", "Item"), t("sku", "SKU"), t("item_type", "Kind"), q("reorder_level", "Reorder level", false), q("available", "Available", false), q("short_by", "Short by", false)] },
  { slug: "stock-expiry", group: "Stock", title: "Batches & expiry", description: "Stock by production batch, soonest expiry first", filters: ["location", "expiry_days"],
    columns: [t("location", "Location"), t("product", "Item"), t("batch_no", "Batch"), t("stock_status", "Status"), q("qty", "Qty"), d("production_date", "Made"),
      d("expiry_date", "Expires"), n("days_left", "Days left", false)] },

  // Bottles
  { slug: "bottle-circulation", group: "Bottles", title: "OLA bottle circulation", description: "Where every OLA bottle is: warehouse, vehicles, shops, customers", filters: [],
    columns: [t("bottle_type", "Bottle"), t("holder", "Where"), n("full", "Full"), n("empty", "Empty"), n("total", "Total")] },
  { slug: "bottle-customers", group: "Bottles", title: "Bottles with customers", description: "Bottles held, deposits held and bottles not covered", filters: ["customer_type", "route"],
    columns: [{ key: "customer", label: "Customer", href: customer }, t("customer_no", "No."), t("bottle_model", "Model"), n("allowed_bottles", "Allowed", false),
      n("ola_held", "Held"), n("deposits_qty", "Deposits (qty)"), m("deposits_amount", "Deposits (Rs.)"), n("uncovered", "Over limit / no deposit"),
      { key: "last_delivered", label: "Last delivery", kind: "datetime" }] },
  { slug: "bottle-holders", group: "Bottles", title: "Bottles on vehicles & at shops", description: "By vehicle (with its driver), shop and warehouse", filters: ["company", "location"],
    columns: [t("holder", "Holder"), t("holder_kind", "Kind"), t("driver", "Driver"), t("company", "Company"), t("bottle_type", "Bottle"), n("full", "Full"), n("empty", "Empty"), n("total", "Total")] },
  { slug: "bottle-external", group: "Bottles", title: "External bottles by company", description: "Held now, taken in from customers and returned in the period", filters: ["period", "company"],
    columns: [t("company", "Company"), n("held_now", "Held now"), n("alert_level", "Alert at", false), n("received_from_customers", "Taken in"), n("returned_to_company", "Returned to them"),
      n("ola_received_back", "OLA bottles received back"), n("handovers", "Hand-overs"), d("last_handover", "Last hand-over")] },
  { slug: "bottle-external-statement", group: "Bottles", title: "Statement with another company", description: "Two-way bottle statement for one company", filters: ["period", "company_required"],
    columns: [d("date", "Date"), t("txn_type", "What"), t("bottle_type", "Bottle"), n("bottles_in", "In"), n("bottles_out", "Out"), t("reference_type", "Reference"), t("reason", "Note")] },
  { slug: "bottle-exposure", group: "Bottles", title: "Bottle value exposure", description: "Value of OLA bottles outside the warehouse, less deposits held", filters: [],
    columns: [t("holder", "Where"), t("bottle_type", "Bottle"), n("qty", "Bottles"), m("unit_value", "Replacement value", false), m("value", "Value"), m("deposits_held", "Deposits held"), m("uncovered", "Not covered")] },
  { slug: "bottle-losses", group: "Bottles", title: "Lost, damaged & written off", description: "Bottles written off, retired or marked damaged", filters: ["period", "company"],
    columns: [d("date", "Date"), t("txn_type", "What"), t("company", "Company"), t("bottle_type", "Bottle"), n("qty", "Qty"), t("bottle_code", "Code"), t("from_holder", "From"),
      m("value", "Value"), t("reason", "Reason")] },
  { slug: "bottle-discrepancies", group: "Bottles", title: "Bottle discrepancies", description: "Shortages, surpluses and bottles found in the wrong place", filters: ["period"],
    columns: [d("date", "Date"), t("exception_type", "Type"), t("description", "Description"), q("expected", "Expected", false), q("actual", "Actual", false),
      q("difference", "Difference"), t("status", "Status"), t("resolution", "Resolution"), t("run_no", "Run"), t("location", "Location")] },
  { slug: "bottle-ageing", group: "Bottles", title: "Bottle ageing", description: "Labelled bottles by days since they last moved", filters: ["company"],
    columns: [t("holder", "Where"), n("d0_30", "0–30 days"), n("d31_60", "31–60"), n("d61_90", "61–90"), n("d90_plus", "Over 90"), n("total", "Total")] },
  { slug: "bottle-retirement", group: "Bottles", title: "Bottles due for retirement", description: "Close to the fill limit, or not in good condition", filters: [],
    columns: [t("code", "Bottle"), t("bottle_type", "Type"), n("fill_count", "Fills", false), n("max_fills", "Limit", false), t("condition", "Condition"), t("holder", "Where now"),
      { key: "last_movement_at", label: "Last moved", kind: "datetime" }] },

  // Delivery
  { slug: "delivery-daily", group: "Delivery", title: "Delivery success by day", description: "Stops delivered, part delivered and failed", filters: ["period", "route"],
    columns: [d("date", "Date"), n("runs", "Runs"), n("stops", "Stops"), n("delivered", "Delivered"), n("partial", "Part"), n("failed", "Failed"), pct("success_pct", "Success")],
    chart: { label: "date", value: "success_pct" } },
  { slug: "delivery-failures", group: "Delivery", title: "Failed deliveries by reason", description: "Why deliveries did not happen", filters: ["period", "route"],
    columns: [t("reason", "Reason"), n("failures", "Failures"), pct("share_pct", "Share"), n("customers", "Customers", false)] },
  { slug: "delivery-drivers", group: "Delivery", title: "Driver performance", description: "Runs, stops, success rate, cash and bottle shortages", filters: ["period"],
    columns: [t("driver", "Driver"), n("runs", "Runs"), n("stops", "Stops"), n("failed", "Failed"), pct("success_pct", "Success"), m("invoiced", "Invoiced"),
      m("cash_short", "Cash short"), n("bottles_short", "Bottles short")] },
  { slug: "delivery-routes", group: "Delivery", title: "Route performance", description: "Stops per run, success and value per route", filters: ["period"],
    columns: [t("route", "Route"), n("runs", "Runs"), n("stops", "Stops"), q("stops_per_run", "Stops / run", false), pct("success_pct", "Success"), m("invoiced", "Invoiced"),
      m("invoiced_per_run", "Per run", false)] },
  { slug: "delivery-vehicles", group: "Delivery", title: "Vehicle performance", description: "Runs, sales and costs of each vehicle", filters: ["period"],
    columns: [t("vehicle", "Vehicle"), n("runs", "Runs"), m("sales", "Sales"), q("litres", "Fuel (L)"), m("fuel", "Fuel"), m("repairs", "Repairs"), m("other_costs", "Other"),
      m("depreciation", "Depreciation"), m("contribution", "Contribution")] },

  // Production & QC
  { slug: "production-summary", group: "Production & QC", title: "Production by product", description: "Planned, produced, rejected, wastage and yield", filters: ["period", "product"],
    columns: [t("product", "Product"), n("batches", "Batches"), n("planned", "Planned"), n("produced", "Produced"), n("rejected", "Rejected"), q("wastage", "Wastage"),
      pct("yield_pct", "Yield"), pct("rejection_pct", "Rejection"), n("released", "Released"), n("failed", "Failed / recalled"), m("avg_unit_cost", "Material cost / unit", false)] },
  { slug: "production-batches", group: "Production & QC", title: "Batch performance", description: "Every batch with its QC results and complaints", filters: ["period", "product"],
    columns: [{ key: "batch_no", label: "Batch", href: (r) => `/production/${r.batch_id}` }, d("production_date", "Date"), t("product", "Product"), t("line", "Line"),
      n("planned_qty", "Planned"), n("produced_qty", "Produced"), n("rejected_qty", "Rejected"), q("wastage_qty", "Wastage"), m("unit_cost", "Unit cost", false),
      t("status", "Status"), n("qc_pass", "QC pass"), n("qc_fail", "QC fail"), n("complaints", "Complaints")] },
  { slug: "production-qc-failures", group: "Production & QC", title: "QC failures", description: "Failed tests and the checks that failed", filters: ["period"],
    columns: [t("test_no", "Test"), d("date", "Date"), t("batch_no", "Batch"), t("product", "Product"), t("test", "Template"), t("failed_checks", "Failed checks"),
      t("batch_status", "Batch now"), t("lab_name", "Lab")] },
  { slug: "production-recalls", group: "Production & QC", title: "Recalls", description: "Recalled batches and how much was recovered", filters: ["period"],
    columns: [t("recall_no", "Recall"), d("date", "Date"), t("batch_no", "Batch"), t("product", "Product"), t("reason", "Reason"), t("status", "Status"),
      n("customers", "Customers"), q("supplied", "Supplied"), q("recovered", "Recovered"), pct("recovered_pct", "Recovered %")] },

  // Finance (operational; the accounts are under Accounting & Reports)
  { slug: "finance-expenses", group: "Finance", title: "Expenses by category", description: "Approved and paid expenses", filters: ["period", "location"],
    columns: [t("category", "Category"), n("expenses", "Expenses"), m("net", "Before VAT"), m("vat", "VAT"), m("total", "Total"), pct("share_pct", "Share")] },
  { slug: "finance-shop-balances", group: "Finance", title: "Water shop balances", description: "Sales, settlements and what dealer shops owe", filters: ["period"],
    columns: [t("shop", "Shop"), t("operating_model", "Model"), m("sales_net", "Sales before VAT"), m("settled_expected", "Settlements expected"), m("settled_received", "Received"),
      m("commission", "Commission"), d("settled_up_to", "Settled up to"), m("dealer_owes", "Dealer owes")] },
  { slug: "finance-deposits", group: "Finance", title: "Bottle deposit liability", description: "Deposits held for customers, with the ledger balance to compare", filters: ["period"],
    columns: [t("bottle_type", "Bottle"), n("customers", "Customers", false), n("bottles", "Bottles"), m("amount", "Deposits held", false), m("taken_in_period", "Taken in period"),
      m("released_in_period", "Refunded / forfeited")] },

  // Complaints
  { slug: "complaints-by-category", group: "Complaints", title: "Complaints by category", description: "Logged, resolved, within due time and hours to resolve", filters: ["period"],
    columns: [t("category", "Category"), n("logged", "Logged"), n("resolved", "Resolved"), n("open", "Still open"), pct("within_sla_pct", "Within due time"),
      q("avg_hours", "Avg. hours to resolve", false)] },
];

export const REPORT_GROUPS: ReportGroup[] = ["Sales", "Customers", "Stock", "Bottles", "Delivery", "Production & QC", "Finance", "Complaints"];

export function reportBySlug(slug: string) {
  return REPORT_CATALOG.find((r) => r.slug === slug) ?? null;
}

/** Filters read from the URL, passed to run_report. */
export function reportFilters(sp: Record<string, string | undefined>) {
  const out: Record<string, string> = {};
  for (const k of ["from", "to", "location_id", "customer_type", "product_id", "company_id", "route_id", "days"]) {
    const v = sp[k];
    if (v && /^[\w-]{1,40}$/.test(v)) out[k] = v;
  }
  return out;
}

const plain = (v: unknown) => (v === null || v === undefined ? "" : String(v));

/** Cell value as text for the CSV download (numbers stay plain numbers). */
export function csvValue(c: Col, v: unknown) {
  if (v === null || v === undefined) return "";
  if (c.kind === "datetime") return new Date(String(v)).toLocaleString("en-GB", { timeZone: "Asia/Colombo" });
  return plain(v);
}

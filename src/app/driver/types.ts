export type Company = { id: string; code: string; name: string; is_own: boolean; policy: string | null };
export type BottleType = { id: string; code: string; name: string };
export type Product = { id: string; sku: string; name: string; barcode: string | null; is_returnable: boolean; bottle_type_id: string | null };

export type Stop = {
  delivery_id: string;
  delivery_no: string;
  stop_sequence: number;
  status: string;
  failure_reason: string | null;
  invoice_id: string | null;
  summary: Record<string, unknown> | null;
  local?: { pending: boolean; receipt?: LocalReceipt; failed_reason?: string };
  order: {
    id: string; order_no: string; notes: string | null; time_window: string | null; expected_ola_returns: number; delivery_charge: number; total: number;
    items: { product_id: string; qty: number; unit_price: number; discount: number }[];
  };
  customer: {
    id: string; customer_no: string; name: string; company_name: string | null; phone: string; phone2: string | null;
    bottle_model: string; allowed_bottles: number; ola_bottles: number; outstanding: number; credit_limit: number;
    external_policy: string | null; payment_terms_days: number; deposits_held: Record<string, number>; prices: Record<string, number>;
    prices_include_tax: boolean;
  };
  address: { address_line: string; city: string | null; gps_lat: number | null; gps_lng: number | null; delivery_instructions: string | null } | null;
};

export type RunData = {
  run: { id: string; run_no: string; run_date: string; status: string; cash_float: number; route: string | null; vehicle: string };
  company: { name: string; vat_no: string | null; receipt_footer: string | null };
  own_company_id: string;
  companies: Company[];
  bottle_types: BottleType[];
  products: Product[];
  vehicle_stock: { product_id: string; qty: number }[];
  vehicle_bottles: { company_id: string; bottle_type_id: string; fill_state: string; qty: number }[];
  cash_collected: number;
  bottle_values: { bottle_type_id: string; company_id: string; deposit: number; external_charge: number }[];
  settings: { external_policy_default: string; require_confirmation: boolean };
  stops: Stop[];
  fetched_at?: string;
};

export type RunSummary = { id: string; run_no: string; run_date: string; status: string; route: string | null; vehicle: string; stops: number; done: number };

export type LocalReceipt = {
  invoice_no: string | null;
  created_at: string;
  print_count: number;
  subtotal_net: number;
  tax_total: number;
  total: number;
  company: { name: string; vat_no?: string | null; footer?: string | null };
  customer: { name: string; customer_no: string };
  lines: { description: string; qty: number; unit_price: number; discount?: number; total: number }[];
  paid: number;
  method: string | null;
  tendered: number | null;
  change: number | null;
  outstanding: number;
  bottles: { issued: Record<string, number>; returned: Record<string, number>; external: { company: string; qty: number }[]; balance: number };
  pending_sync?: boolean;
};

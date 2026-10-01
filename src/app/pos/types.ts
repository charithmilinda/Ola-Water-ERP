export type PosLocation = { id: string; code: string; name: string; type: string; shop_id: string | null; operating_model: string | null; till_open: boolean };

export type PosProduct = { id: string; sku: string; name: string; barcode: string | null; is_returnable: boolean; bottle_type_id: string | null;
  price: number | null; tax_rate: number | null; stock: number };

export type PosSession = { id: string; session_no: string; receipt_prefix: string; opening_float: number; opened_at: string; opened_by: string;
  next_seq: number; cash_in: number; card_in: number; sales: number };

export type PosBoot = {
  location: { id: string; code: string; name: string; type: string };
  shop: { id: string; name: string; operating_model: string; phone: string | null; address: string | null } | null;
  is_dealer: boolean;
  walk_in_customer_id: string | null;
  walk_in_deposits: Record<string, number>;
  walk_in_bottles: number;
  includes_tax: boolean;
  company: { name: string; vat_no: string | null; footer: string | null };
  own_company_id: string;
  companies: { id: string; code: string; name: string; is_own: boolean; policy: string | null }[];
  bottle_types: { id: string; code: string; name: string }[];
  products: PosProduct[];
  bottle_values: { bottle_type_id: string; company_id: string; deposit: number; external_charge: number }[];
  bottles_here: { company_id: string; bottle_type_id: string; fill_state: string; qty: number }[];
  settings: { external_policy_default: string; discount_percent: number; can_discount: boolean };
  session: PosSession | null;
  fetched_at: string;
};

export type PosCustomer = { id: string; customer_no: string; name: string; phone: string; bottle_model: string; allowed_bottles: number;
  credit_limit: number; outstanding: number; ola_bottles: number; external_policy: string | null; status: string;
  deposits_held: Record<string, number>; prices: Record<string, number> | null };

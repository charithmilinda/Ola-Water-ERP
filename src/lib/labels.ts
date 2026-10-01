import type { BadgeTone } from "@/components/ui/badge";

export const ORDER_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  draft: { label: "Draft", tone: "neutral" },
  on_hold: { label: "On hold", tone: "red" },
  confirmed: { label: "Confirmed", tone: "blue" },
  assigned: { label: "Assigned", tone: "blue" },
  loaded: { label: "Loaded", tone: "blue" },
  out_for_delivery: { label: "Out for delivery", tone: "amber" },
  delivered: { label: "Delivered", tone: "green" },
  partially_delivered: { label: "Partly delivered", tone: "amber" },
  failed: { label: "Failed", tone: "red" },
  cancelled: { label: "Cancelled", tone: "neutral" },
};

export const RUN_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  planned: { label: "Planned", tone: "neutral" },
  loaded: { label: "Loaded", tone: "blue" },
  in_progress: { label: "On the road", tone: "amber" },
  checked_in: { label: "Checked in — differences", tone: "red" },
  closed: { label: "Closed", tone: "green" },
  cancelled: { label: "Cancelled", tone: "neutral" },
};

export const DELIVERY_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  pending: { label: "Pending", tone: "neutral" },
  delivered: { label: "Delivered", tone: "green" },
  partially_delivered: { label: "Partly delivered", tone: "amber" },
  failed: { label: "Failed", tone: "red" },
  cancelled: { label: "Cancelled", tone: "neutral" },
};

export const INVOICE_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  open: { label: "Unpaid", tone: "amber" },
  partially_paid: { label: "Part paid", tone: "amber" },
  paid: { label: "Paid", tone: "green" },
  credit: { label: "Credit", tone: "blue" },
  void: { label: "Void", tone: "neutral" },
};

export const SEVERITY: Record<string, { label: string; tone: BadgeTone }> = {
  critical: { label: "Critical", tone: "red" },
  warning: { label: "Warning", tone: "amber" },
  info: { label: "Info", tone: "blue" },
};

export const CUSTOMER_TYPES = [
  ["household", "Household"],
  ["office", "Office"],
  ["hotel", "Hotel"],
  ["restaurant", "Restaurant"],
  ["shop", "Shop"],
  ["supermarket", "Supermarket"],
  ["institution", "Institution"],
  ["distributor", "Distributor"],
  ["water_shop", "Water shop"],
  ["corporate", "Corporate"],
] as const;

export const POLICIES = [
  ["accept_one_for_one", "Accept one-for-one"],
  ["accept_with_charge", "Accept with a charge"],
  ["accept_no_credit", "Accept, no credit"],
  ["refuse", "Refuse"],
] as const;

export const PAYMENT_METHODS = [
  ["cash", "Cash"],
  ["card", "Card"],
  ["qr", "QR payment"],
  ["bank_transfer", "Bank transfer"],
  ["cheque", "Cheque"],
] as const;

export const FAIL_REASONS = [
  "Customer not available",
  "Customer refused",
  "Wrong or unclear address",
  "No payment available",
  "Premises closed",
  "Vehicle problem",
  "Ran out of stock",
  "Other",
];

export function statusBadge(map: Record<string, { label: string; tone: BadgeTone }>, s: string) {
  return map[s] ?? { label: s.replace(/_/g, " "), tone: "neutral" as BadgeTone };
}

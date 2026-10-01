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

export const BATCH_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  planned: { label: "Planned", tone: "neutral" },
  in_production: { label: "In production", tone: "blue" },
  qc_hold: { label: "QC hold", tone: "amber" },
  released: { label: "Released", tone: "green" },
  failed: { label: "Failed QC", tone: "red" },
  recalled: { label: "Recalled", tone: "red" },
  cancelled: { label: "Cancelled", tone: "neutral" },
};

export const PR_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  submitted: { label: "Waiting approval", tone: "amber" },
  approved: { label: "Approved", tone: "blue" },
  rejected: { label: "Rejected", tone: "red" },
  ordered: { label: "Ordered", tone: "green" },
  cancelled: { label: "Withdrawn", tone: "neutral" },
};

export const PO_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  pending_approval: { label: "Waiting approval", tone: "amber" },
  approved: { label: "Ordered", tone: "blue" },
  partially_received: { label: "Part received", tone: "amber" },
  received: { label: "Received", tone: "green" },
  closed: { label: "Closed", tone: "neutral" },
  cancelled: { label: "Cancelled", tone: "neutral" },
};

export const SUPPLIER_INVOICE_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  on_hold: { label: "On hold — mismatch", tone: "red" },
  approved: { label: "To pay", tone: "amber" },
  partially_paid: { label: "Part paid", tone: "amber" },
  paid: { label: "Paid", tone: "green" },
  void: { label: "Void", tone: "neutral" },
};

export const ITEM_TYPES = [
  ["raw_material", "Raw material"],
  ["packaging", "Packaging (caps, labels, preforms)"],
  ["chemical", "Chemical"],
  ["consumable", "Consumable (filters, cleaning)"],
  ["spare_part", "Spare part"],
] as const;

export const UNITS = [
  ["piece", "Piece"], ["kg", "Kg"], ["g", "Gram"], ["litre", "Litre"], ["ml", "ml"], ["roll", "Roll"], ["box", "Box"],
  ["pack", "Pack"], ["metre", "Metre"], ["set", "Set"], ["unit", "Unit"],
] as const;

export const PRODUCTION_STAGES = [
  ["raw_water", "Raw water"],
  ["filtration", "Filtration"],
  ["ro", "Reverse osmosis"],
  ["uv", "UV"],
  ["ozone", "Ozone"],
  ["storage", "Storage tank"],
  ["washing", "Bottle washing / sanitising"],
  ["filling", "Filling"],
  ["capping", "Capping"],
  ["labelling", "Labelling"],
  ["finished", "Finished goods"],
] as const;

export const SHIFTS = [["morning", "Morning"], ["day", "Day"], ["evening", "Evening"], ["night", "Night"]] as const;

export const STOCK_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  available: { label: "Available", tone: "green" },
  qc_hold: { label: "QC hold", tone: "amber" },
  quarantine: { label: "Quarantine", tone: "red" },
  damaged: { label: "Damaged", tone: "neutral" },
};

export const EMPLOYMENT_TYPES = [["permanent", "Permanent"], ["probation", "Probation"], ["contract", "Contract"], ["casual", "Casual / daily"]] as const;

export const ATTENDANCE_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  present: { label: "Present", tone: "green" },
  half_day: { label: "Half day", tone: "amber" },
  absent: { label: "Absent", tone: "red" },
  leave: { label: "Leave", tone: "blue" },
  holiday: { label: "Holiday", tone: "neutral" },
  off: { label: "Day off", tone: "neutral" },
};

export const LEAVE_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  pending: { label: "Waiting", tone: "amber" },
  approved: { label: "Approved", tone: "green" },
  rejected: { label: "Rejected", tone: "red" },
  cancelled: { label: "Cancelled", tone: "neutral" },
};

export const PAYROLL_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  draft: { label: "Draft — check it", tone: "amber" },
  approved: { label: "Approved — to pay", tone: "blue" },
  paid: { label: "Paid", tone: "green" },
  cancelled: { label: "Cancelled", tone: "neutral" },
};

export const VEHICLE_DOC_TYPES = [["insurance", "Insurance"], ["revenue_licence", "Revenue licence"], ["emission_test", "Emission test"],
  ["fitness", "Fitness certificate"], ["other", "Other"]] as const;
export const SERVICE_KINDS = [["service", "Scheduled service"], ["repair", "Repair"], ["tyres", "Tyres"], ["battery", "Battery"], ["accident", "Accident damage"],
  ["other", "Other"]] as const;
export const FUEL_TYPES = [["diesel", "Diesel"], ["petrol", "Petrol"], ["electric", "Electric"], ["hybrid", "Hybrid"], ["other", "Other"]] as const;
export const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

export function statusBadge(map: Record<string, { label: string; tone: BadgeTone }>, s: string) {
  return map[s] ?? { label: s.replace(/_/g, " "), tone: "neutral" as BadgeTone };
}

export const APPROVAL_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  pending: { label: "Waiting", tone: "amber" },
  executing: { label: "Being carried out", tone: "blue" },
  approved: { label: "Approved", tone: "green" },
  rejected: { label: "Rejected", tone: "red" },
  cancelled: { label: "Withdrawn", tone: "neutral" },
};

export const COMPLAINT_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  new: { label: "New", tone: "red" },
  assigned: { label: "Assigned", tone: "amber" },
  in_progress: { label: "In progress", tone: "blue" },
  resolved: { label: "Resolved", tone: "green" },
  closed: { label: "Closed", tone: "neutral" },
};

export const PRIORITY: Record<string, { label: string; tone: BadgeTone }> = {
  urgent: { label: "Urgent", tone: "red" },
  high: { label: "High", tone: "amber" },
  normal: { label: "Normal", tone: "blue" },
  low: { label: "Low", tone: "neutral" },
};

export const COMPLAINT_CHANNELS = [["phone", "Phone call"], ["whatsapp", "WhatsApp"], ["email", "Email"], ["walk_in", "Walk-in"],
  ["driver", "Told the driver"], ["shop", "At a water shop"], ["sales_rep", "Sales rep"], ["other", "Other"]] as const;

export const MESSAGE_STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  queued: { label: "Queued", tone: "amber" },
  sending: { label: "Sending", tone: "blue" },
  sent: { label: "Sent", tone: "green" },
  failed: { label: "Failed", tone: "red" },
  cancelled: { label: "Cancelled", tone: "neutral" },
};

export const DOC_ENTITY_TYPES = [["company", "Company"], ["customer", "Customer"], ["supplier", "Supplier"], ["employee", "Employee"],
  ["vehicle", "Vehicle"], ["asset", "Fixed asset"], ["batch", "Production batch"], ["shop", "Water shop"]] as const;

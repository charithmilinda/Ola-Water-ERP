import { Clock, FileSpreadsheet, Receipt, Scale, TrendingUp, Wallet } from "lucide-react";

export const REPORTS: { slug: string; title: string; description: string; icon: typeof Scale }[] = [
  { slug: "profit-loss", title: "Profit & Loss", description: "Income, cost of sales and expenses for a period, with the previous period", icon: TrendingUp },
  { slug: "balance-sheet", title: "Balance Sheet", description: "What the business owns and owes on a date", icon: Scale },
  { slug: "cash-flow", title: "Cash Flow", description: "Where cash came from and went, by purpose", icon: Wallet },
  { slug: "trial-balance", title: "Trial Balance", description: "Every account: opening, movements, closing", icon: FileSpreadsheet },
  { slug: "ar-ageing", title: "Customers — ageing", description: "What customers owe, by how late it is", icon: Clock },
  { slug: "ap-ageing", title: "Suppliers — ageing", description: "What the business owes, by how late it is", icon: Clock },
  { slug: "vat", title: "VAT", description: "Output and input VAT for a period, and VAT returns", icon: Receipt },
];

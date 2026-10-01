import { notFound } from "next/navigation";
import { getAccess } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { Receipt80, type ReceiptData } from "@/components/receipt";
import { PosReceiptActions } from "./receipt-actions";

export const dynamic = "force-dynamic";

export default async function PosReceiptPage({ params }: { params: Promise<{ id: string }> }) {
  await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_pos_receipt", { p_sale: id });
  if (error || !data) notFound();
  const r = data as ReceiptData;
  return (
    <div className="min-h-dvh bg-surface py-6 print:bg-white print:py-0">
      <PosReceiptActions saleId={id} printCount={r.print_count ?? 0} />
      <Receipt80 r={r} />
    </div>
  );
}

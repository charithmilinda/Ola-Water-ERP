import { notFound } from "next/navigation";
import { getAccess } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { AutoPrint } from "../../labels/[id]/auto-print";
import { PayslipView, type PayslipData } from "../../payslip-view";

export const dynamic = "force-dynamic";

export default async function PrintPayslip({ params }: { params: Promise<{ id: string }> }) {
  await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("payslip_details", { p_payslip: id });
  if (error || !data) notFound();
  return (
    <div className="min-h-dvh bg-surface py-6 print:bg-white print:py-0">
      <div className="no-print mx-auto mb-4 flex w-[148mm] justify-end"><AutoPrint /></div>
      <PayslipView d={data as PayslipData} />
    </div>
  );
}

import { notFound } from "next/navigation";
import { getAccess } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { AutoPrint } from "../../labels/[id]/auto-print";
import { PayslipView, type PayslipData } from "../../payslip-view";

export const dynamic = "force-dynamic";

/** Every payslip of one payroll, one per page. */
export default async function PrintPayslips({ params }: { params: Promise<{ id: string }> }) {
  await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data: ids, error } = await supabase.from("payslips").select("id, emp_no").eq("run_id", id).order("emp_no");
  if (error || !ids || ids.length === 0) notFound();
  const slips = await Promise.all(ids.map(async (s) => (await supabase.rpc("payslip_details", { p_payslip: s.id })).data as PayslipData | null));
  return (
    <div className="min-h-dvh bg-surface py-6 print:bg-white print:py-0">
      <div className="no-print mx-auto mb-4 flex w-[148mm] justify-between text-sm"><span>{ids.length} payslip(s)</span><AutoPrint /></div>
      {slips.filter(Boolean).map((d, i) => <PayslipView key={i} d={d!} />)}
    </div>
  );
}

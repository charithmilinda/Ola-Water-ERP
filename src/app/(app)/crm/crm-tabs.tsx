import Link from "next/link";
import { buttonVariants } from "@/components/ui/button";

const TABS = [["/crm", "Leads"], ["/crm/campaigns", "Campaigns"], ["/crm/promotions", "Promotions"], ["/crm/segments", "Segments"]] as const;

export function CrmTabs({ active }: { active: string }) {
  return (
    <div className="mb-4 flex flex-wrap gap-1">
      {TABS.map(([href, label]) => <Link key={href} href={href} className={buttonVariants({ variant: href === active ? "primary" : "secondary", size: "sm" })}>{label}</Link>)}
    </div>
  );
}

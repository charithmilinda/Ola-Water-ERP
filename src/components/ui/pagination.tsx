import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { buttonVariants } from "./button";
import { cn } from "@/lib/cn";

export function Pagination({
  page,
  pageSize,
  total,
  hrefFor,
}: {
  page: number;
  pageSize: number;
  total: number;
  hrefFor: (page: number) => string;
}) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const from = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const to = Math.min(total, page * pageSize);
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 px-4 py-3 text-sm text-muted">
      <span className="num">
        {from.toLocaleString()}–{to.toLocaleString()} of {total.toLocaleString()}
      </span>
      <div className="flex gap-2">
        {page > 1 ? (
          <Link className={buttonVariants({ variant: "secondary", size: "sm" })} href={hrefFor(page - 1)}>
            <ChevronLeft className="h-4 w-4" /> Previous
          </Link>
        ) : (
          <span className={cn(buttonVariants({ variant: "secondary", size: "sm" }), "opacity-40")} aria-disabled>
            <ChevronLeft className="h-4 w-4" /> Previous
          </span>
        )}
        {page < pages ? (
          <Link className={buttonVariants({ variant: "secondary", size: "sm" })} href={hrefFor(page + 1)}>
            Next <ChevronRight className="h-4 w-4" />
          </Link>
        ) : (
          <span className={cn(buttonVariants({ variant: "secondary", size: "sm" }), "opacity-40")} aria-disabled>
            Next <ChevronRight className="h-4 w-4" />
          </span>
        )}
      </div>
    </div>
  );
}

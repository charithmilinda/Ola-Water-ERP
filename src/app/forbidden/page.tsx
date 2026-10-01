import Link from "next/link";
import { ShieldAlert } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";

export default function Forbidden() {
  return (
    <div className="flex min-h-dvh flex-col items-center justify-center px-6 text-center">
      <div className="mb-4 rounded-full bg-amber-50 p-3 text-amber-700">
        <ShieldAlert className="h-7 w-7" />
      </div>
      <h1 className="text-xl font-semibold text-navy-900">You don’t have access to this page</h1>
      <p className="mt-2 max-w-md text-sm text-muted">Ask an administrator to grant your role the required permission.</p>
      <Link href="/" className={buttonVariants({ className: "mt-6" })}>
        Back to Home
      </Link>
    </div>
  );
}

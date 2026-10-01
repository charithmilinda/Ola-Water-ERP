import { LogOut } from "lucide-react";
import { signOut } from "@/app/login/actions";
import type { Access } from "@/lib/access";

export function UserMenu({ access }: { access: Access }) {
  const initials = access.full_name
    .split(/\s+/)
    .map((p) => p[0])
    .slice(0, 2)
    .join("")
    .toUpperCase();
  const roleLabel = access.roles.map((r) => r.name).join(", ") || "No role assigned";
  return (
    <details className="relative">
      <summary className="flex cursor-pointer list-none items-center gap-2.5 rounded-lg px-2 py-1.5 hover:bg-ola-50 [&::-webkit-details-marker]:hidden">
        <span className="flex h-8 w-8 items-center justify-center rounded-full bg-navy-900 text-xs font-semibold text-white">{initials}</span>
        <span className="hidden text-left sm:block">
          <span className="block text-sm font-medium leading-tight text-navy-900">{access.full_name}</span>
          <span className="block max-w-48 truncate text-xs leading-tight text-muted">{roleLabel}</span>
        </span>
      </summary>
      <div className="absolute right-0 z-40 mt-2 w-64 rounded-xl border border-line bg-white p-2 shadow-lg">
        <div className="border-b border-line px-3 pb-2 pt-1">
          <p className="text-sm font-medium text-navy-900">{access.full_name}</p>
          <p className="truncate text-xs text-muted">{access.email}</p>
          <p className="mt-1 text-xs text-muted">{roleLabel}</p>
        </div>
        <form action={signOut} className="pt-1">
          <button type="submit" className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-navy-800 hover:bg-ola-50">
            <LogOut className="h-4 w-4" /> Sign out
          </button>
        </form>
      </div>
    </details>
  );
}

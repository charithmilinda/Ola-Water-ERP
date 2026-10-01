import type { LucideIcon } from "lucide-react";

export function EmptyState({ icon: Icon, title, description }: { icon: LucideIcon; title: string; description?: string }) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-14 text-center">
      <div className="mb-3 rounded-full bg-ola-50 p-3 text-ola-600">
        <Icon className="h-6 w-6" aria-hidden />
      </div>
      <p className="font-medium text-navy-900">{title}</p>
      {description && <p className="mt-1 max-w-md text-sm text-muted">{description}</p>}
    </div>
  );
}

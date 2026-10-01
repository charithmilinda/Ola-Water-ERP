import { humanize } from "@/lib/format";

type Row = {
  action: string;
  old_values: Record<string, unknown> | null;
  new_values: Record<string, unknown> | null;
  changed_fields: string[] | null;
};

const HIDDEN = new Set(["updated_at", "created_at", "id"]);

function show(v: unknown): string {
  if (v === null || v === undefined || v === "") return "—";
  if (typeof v === "object") return JSON.stringify(v);
  return String(v);
}

/** Before / after comparison for edits, field list for creates and deletes. */
export function AuditDetails({ row }: { row: Row }) {
  const { old_values: before, new_values: after } = row;

  if (before && after) {
    const fields = (row.changed_fields ?? []).filter((k) => !HIDDEN.has(k));
    if (fields.length === 0) return <span className="text-xs text-muted">No visible field changes</span>;
    return (
      <table className="w-full text-xs">
        <thead>
          <tr className="text-left text-muted">
            <th className="py-1 pr-3 font-semibold">Field</th>
            <th className="py-1 pr-3 font-semibold">Before</th>
            <th className="py-1 font-semibold">After</th>
          </tr>
        </thead>
        <tbody>
          {fields.map((k) => (
            <tr key={k} className="border-t border-line">
              <td className="py-1 pr-3 font-medium">{humanize(k)}</td>
              <td className="py-1 pr-3 text-red-700 line-through decoration-red-300">{show(before[k])}</td>
              <td className="py-1 text-emerald-800">{show(after[k])}</td>
            </tr>
          ))}
        </tbody>
      </table>
    );
  }

  const values = after ?? before;
  if (!values) return null;
  const entries = Object.entries(values).filter(([k, v]) => !HIDDEN.has(k) && v !== null && v !== "");
  if (entries.length === 0) return null;

  return (
    <details className="group">
      <summary className="cursor-pointer text-xs font-medium text-ola-700 hover:underline">
        {after ? "Show recorded values" : "Show values before deletion"} ({entries.length})
      </summary>
      <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
        {entries.map(([k, v]) =>
          k === "lines" && Array.isArray(v) ? (
            <div key={k} className="col-span-2">
              <dt className="mb-1 font-medium">Lines</dt>
              <dd>
                <table className="w-full">
                  <tbody>
                    {(v as { account: string; debit: number; credit: number }[]).map((l, i) => (
                      <tr key={i} className="border-t border-line">
                        <td className="py-0.5 pr-3">{l.account}</td>
                        <td className="num py-0.5 pr-3 text-right">{Number(l.debit) ? Number(l.debit).toFixed(2) : ""}</td>
                        <td className="num py-0.5 text-right">{Number(l.credit) ? Number(l.credit).toFixed(2) : ""}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </dd>
            </div>
          ) : (
            <div key={k} className="contents">
              <dt className="font-medium text-muted">{humanize(k)}</dt>
              <dd className="break-all">{show(v)}</dd>
            </div>
          ),
        )}
      </dl>
    </details>
  );
}

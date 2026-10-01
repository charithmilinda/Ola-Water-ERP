import Link from "next/link";
import { FileText } from "lucide-react";
import { can, type Access } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate } from "@/lib/format";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { FormDialog } from "@/components/ui/form-dialog";
import { uploadDocument } from "@/app/(app)/documents/actions";
import { DocumentUploadFields } from "./upload-fields";

type Row = { id: string; doc_no: string; category: string; title: string; reference_no: string | null; file_path: string; file_name: string;
  expires_on: string | null; created_at: string };

/** Documents attached to a customer, supplier, employee, vehicle, asset, batch or shop. */
export async function DocumentsCard({ access, entityType, entityId, categories, returnTo }: {
  access: Access; entityType: string; entityId: string; categories: string[]; returnTo: string;
}) {
  const supabase = await createClient();
  const [{ data: rows }, { data: cats }] = await Promise.all([
    supabase.rpc("entity_documents", { p_type: entityType, p_id: entityId }),
    supabase.from("document_categories").select("code, name, has_expiry, manage_permission").eq("is_active", true).in("code", categories).order("sort_order"),
  ]);
  const list = (rows ?? []) as Row[];
  const uploadable = (cats ?? []).filter((c) => can(access, c.manage_permission));
  if (list.length === 0 && uploadable.length === 0) return null;
  const links: Record<string, string> = {};
  for (const r of list.slice(0, 20)) {
    const { data } = await supabase.storage.from("documents").createSignedUrl(r.file_path, 3600, { download: r.file_name });
    if (data?.signedUrl) links[r.id] = data.signedUrl;
  }
  const today = new Date().toISOString().slice(0, 10);
  return (
    <Card>
      <CardHeader title="Documents" actions={uploadable.length > 0 && (
        <FormDialog trigger="Upload" triggerSize="sm" title="Upload a document" submitLabel="Upload" action={uploadDocument}
          hidden={{ return_to: returnTo }} wide>
          <DocumentUploadFields categories={uploadable} entity={{ type: entityType, id: entityId }} />
        </FormDialog>)} />
      {list.length === 0 ? <CardBody><p className="text-sm text-muted">No documents yet.</p></CardBody> : (
        <Table>
          <thead><tr><Th>Document</Th><Th>Type</Th><Th>Expires</Th><Th /></tr></thead>
          <tbody>{list.map((r) => (
            <tr key={r.id}>
              <Td><Link href={`/documents/${r.id}`} className="font-medium text-ola-700 hover:underline"><FileText className="mr-1 inline h-3.5 w-3.5" />{r.title}</Link>
                <span className="block text-xs text-muted">{r.doc_no}{r.reference_no ? ` · ${r.reference_no}` : ""}</span></Td>
              <Td className="text-sm">{r.category}</Td>
              <Td className={r.expires_on && r.expires_on < today ? "font-semibold text-red-700" : ""}>{r.expires_on ? formatDate(r.expires_on) : "—"}</Td>
              <Td className="text-right">{links[r.id] && <a href={links[r.id]} className="text-sm text-ola-700 hover:underline">Download</a>}</Td>
            </tr>))}</tbody>
        </Table>
      )}
    </Card>
  );
}

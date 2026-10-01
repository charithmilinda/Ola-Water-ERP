"use server";

import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";
import { parseLines } from "@/lib/lines";

const P = ["/materials", "/inventory", "/production"];

export async function saveMaterial(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_product", {
    p_id: id,
    p: {
      sku: str(f, "sku"), name: str(f, "name"), item_type: str(f, "item_type"), unit: str(f, "unit"),
      size_label: str(f, "size_label"), tax_code: str(f, "tax_code"), cost_price: str(f, "cost_price") || "0",
      reorder_level: str(f, "reorder_level") || "0", sort_order: "0", units_per_pack: "1",
      is_active: id ? f.get("is_active") === "on" : true,
    },
    p_reason: str(f, "reason") || (id ? null : "New material"),
  }, id ? "Material saved." : "Material added.", P);
}

export async function saveBom(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const lines = parseLines(f.get("lines")).map((l) => ({ material_id: l.item_id, qty_per_unit: Number(l.qty_per_unit || 0) }));
  return runRpc<number>("set_bill_of_materials", { p_product: str(f, "product_id"), p_lines: lines, p_reason: str(f, "reason") || "Bill of materials" },
    (n) => `Bill of materials saved (${n} material${n === 1 ? "" : "s"}).`, P);
}

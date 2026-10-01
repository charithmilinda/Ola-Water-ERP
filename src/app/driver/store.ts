"use client";

// Tiny IndexedDB wrapper: a key-value store for cached run data and an
// outbox of transactions waiting to reach the server.

const DB = "ola-driver";
const VERSION = 1;

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains("kv")) db.createObjectStore("kv");
      if (!db.objectStoreNames.contains("outbox")) db.createObjectStore("outbox", { keyPath: "id" });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function tx<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  return new Promise((resolve, reject) => {
    const t = db.transaction(store, mode);
    const req = fn(t.objectStore(store));
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export const kv = {
  get: <T>(key: string) => tx<T | undefined>("kv", "readonly", (s) => s.get(key) as IDBRequest<T | undefined>),
  set: (key: string, value: unknown) => tx("kv", "readwrite", (s) => s.put(value, key)),
  del: (key: string) => tx("kv", "readwrite", (s) => s.delete(key)),
};

export type OutboxItem = {
  id: string; // client_txn_id
  fn: "complete_delivery" | "fail_delivery" | "driver_start_run";
  args: Record<string, unknown>;
  run_id: string;
  delivery_id?: string;
  label: string;
  created_at: string;
  status: "pending" | "error";
  error?: string;
  attempts: number;
  photo?: { data_url: string; path: string; uploaded: boolean };
};

export const outbox = {
  all: async () => (await tx<OutboxItem[]>("outbox", "readonly", (s) => s.getAll() as IDBRequest<OutboxItem[]>)).sort((a, b) => a.created_at.localeCompare(b.created_at)),
  put: (item: OutboxItem) => tx("outbox", "readwrite", (s) => s.put(item)),
  del: (id: string) => tx("outbox", "readwrite", (s) => s.delete(id)),
};

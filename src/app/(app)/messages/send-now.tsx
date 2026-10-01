"use client";

import { useState, useTransition } from "react";
import { Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import { sendNow } from "./actions";

export function SendNowButton() {
  const [msg, setMsg] = useState("");
  const [pending, start] = useTransition();
  return (
    <span className="flex items-center gap-2">
      {msg && <span className="text-sm text-muted">{msg}</span>}
      <Button type="button" size="md" disabled={pending} onClick={() => start(async () => setMsg((await sendNow()).message))}>
        <Send className="h-4 w-4" /> {pending ? "Sending…" : "Send now"}
      </Button>
    </span>
  );
}

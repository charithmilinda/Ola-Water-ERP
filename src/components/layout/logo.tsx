export function OlaMark({ className = "h-8 w-8" }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" className={className} aria-hidden>
      <rect width="32" height="32" rx="8" fill="#1868d6" />
      <path d="M16 6c3.6 4.6 7 8.7 7 12.4A7 7 0 0 1 9 18.4C9 14.7 12.4 10.6 16 6Z" fill="#fff" />
      <path d="M12.6 19.2a3.6 3.6 0 0 0 3.4 3.3" stroke="#1868d6" strokeWidth="1.6" strokeLinecap="round" fill="none" />
    </svg>
  );
}

export function OlaWordmark() {
  return (
    <span className="flex items-center gap-2.5">
      <OlaMark />
      <span className="leading-tight">
        <span className="block text-[15px] font-semibold tracking-tight text-navy-900">OLA Water</span>
        <span className="block text-[11px] font-medium uppercase tracking-wider text-muted">ERP</span>
      </span>
    </span>
  );
}

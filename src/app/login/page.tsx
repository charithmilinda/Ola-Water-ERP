import type { Metadata } from "next";
import { OlaMark } from "@/components/layout/logo";
import { LoginForm } from "./login-form";

export const metadata: Metadata = { title: "Sign in" };

const NOTICES: Record<string, string> = {
  inactive: "Your account is deactivated. Contact your administrator.",
};

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; error?: string }> }) {
  const { next, error } = await searchParams;
  return (
    <div className="grid min-h-dvh lg:grid-cols-[1fr_minmax(0,560px)]">
      <section className="relative hidden overflow-hidden bg-navy-900 p-12 text-white lg:flex lg:flex-col lg:justify-between">
        <div
          aria-hidden
          className="pointer-events-none absolute -right-32 -top-32 h-[520px] w-[520px] rounded-full bg-ola-600/30 blur-3xl"
        />
        <div className="relative flex items-center gap-3">
          <OlaMark className="h-10 w-10" />
          <span className="text-lg font-semibold tracking-tight">OLA Water</span>
        </div>
        <div className="relative max-w-lg">
          <h1 className="text-4xl font-semibold leading-tight tracking-tight">
            Every bottle, every rupee,
            <br />
            accounted for.
          </h1>
          <p className="mt-4 text-base text-ola-100/80">
            Production, deliveries, water shops, bottle recovery and finance — in one system with a complete audit trail.
          </p>
        </div>
        <p className="relative text-sm text-ola-100/60">OLA Water Sri Lanka · Internal system for authorised staff</p>
      </section>

      <section className="flex items-center justify-center px-6 py-12">
        <div className="w-full max-w-sm">
          <div className="mb-8 flex items-center gap-3 lg:hidden">
            <OlaMark className="h-10 w-10" />
            <span className="text-lg font-semibold tracking-tight text-navy-900">OLA Water ERP</span>
          </div>
          <h2 className="text-2xl font-semibold tracking-tight text-navy-900">Sign in</h2>
          <p className="mb-6 mt-1 text-sm text-muted">Use the email and password issued by your administrator.</p>
          <LoginForm next={next} notice={error ? NOTICES[error] : undefined} />
        </div>
      </section>
    </div>
  );
}

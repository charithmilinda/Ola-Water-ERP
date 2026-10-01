import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    // QC certificates and lab reports are uploaded through a server action (max 10 MB each)
    serverActions: { bodySizeLimit: "11mb" },
  },
};

export default nextConfig;

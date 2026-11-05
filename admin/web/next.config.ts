import type { NextConfig } from "next";

// Backend FastAPI (admin/backend). Le chiamate HTTP del browser passano da qui (stessa origine, niente CORS);
// il WebSocket della console va diretto a NEXT_PUBLIC_BACKEND_WS. Vedi .env.example.
const BACKEND_URL = (process.env.BACKEND_URL || "http://localhost:8000").replace(/\/$/, "");

const nextConfig: NextConfig = {
  devIndicators: false,
  async rewrites() {
    return [
      { source: "/api/:path*", destination: `${BACKEND_URL}/api/:path*` },
      { source: "/camera", destination: `${BACKEND_URL}/camera` },
    ];
  },
  cacheComponents: true,
  partialPrefetching: true,
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;

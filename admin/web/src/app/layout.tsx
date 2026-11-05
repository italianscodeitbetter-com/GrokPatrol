import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Script from "next/script";
import { Sidebar } from "@/components/Sidebar";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "GrokPatrol",
  description: "Control room console for the patrol robot dog",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="h-full font-sans">
        <div className="flex h-full">
          <Sidebar />
          {/* Il contenuto è un pannello accanto alla sidebar (come in Pocket Editor): bordo, angoli arrotondati, scorre da solo */}
          <main className="min-w-0 flex-1 overflow-y-auto bg-app pt-12 md:my-2 md:mr-2 md:h-[calc(100%-1rem)] md:rounded-xl md:border md:border-line md:pt-0">
            {children}
          </main>
        </div>
        {/* Commenta (dev only): comments on the page → comments/app.json, served by `commenta` on port 4747 */}
        {process.env.NODE_ENV === "development" && <Script src="http://127.0.0.1:4747/commenta.js" strategy="lazyOnload" />}
      </body>
    </html>
  );
}

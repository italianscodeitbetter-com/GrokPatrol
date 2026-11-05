import type { Metadata } from "next";
import { AutomationBuilder } from "@/components/AutomationBuilder";

export const metadata: Metadata = { title: "New automation · GrokPatrol" };

export default function NewAutomationPage() {
  return <AutomationBuilder />;
}

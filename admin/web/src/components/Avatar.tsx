import Image from "next/image";
import { profile } from "@/lib/profile";

/** La foto profilo dell'operatore, tonda. La misura arriva da className (es. size-9). */
export function Avatar({ className = "size-9" }: { className?: string }) {
  return (
    <Image
      src={profile.avatar}
      alt={profile.name}
      width={72}
      height={72}
      className={`rounded-full bg-user object-cover ${className}`}
    />
  );
}

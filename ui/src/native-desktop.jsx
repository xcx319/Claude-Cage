import React, { useEffect, useSyncExternalStore } from "react";
import { Monitor } from "lucide-react";
import { getClientContext, runtimeSocketURL } from "./client-context.mjs";
import { createNativeDesktopSession } from "./native-desktop-session.mjs";

export const nativeDesktop = createNativeDesktopSession({ context: getClientContext,
  connect: () => new WebSocket(runtimeSocketURL("/macos/native-desktop")) });
export function useNativeDesktopState() { return useSyncExternalStore(nativeDesktop.subscribe, nativeDesktop.snapshot); }
export function useNativeDesktopActive() { return useNativeDesktopState().phase === "open"; }

// This owner stays mounted across launcher/workbench switches, but is removed
// by the account gate when the account locks or the application goes away.
export function NativeDesktopLifetime({ children }) {
  useEffect(() => () => nativeDesktop.close(), []);
  return children;
}

export function NativeDesktopButton({ ready, onStatus = () => {} }) {
  const { phase } = useNativeDesktopState();
  const open = phase !== "closed";
  function toggle() {
    if (open) { nativeDesktop.close(); return; }
    nativeDesktop.open().catch(error => onStatus(error.message));
  }
  return <button type="button" className={`sidebar-link ${open ? "selected" : ""}`} disabled={!ready && !open}
    onClick={toggle} aria-pressed={open}><Monitor size={17} />{open ? "关闭完整桌面" : "完整 Mac 桌面"}</button>;
}

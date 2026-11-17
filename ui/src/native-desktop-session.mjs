// One local desktop lease is shared by the launcher and workbench. Switching
// views must not acquire a second lease or close the virtual machine's window.
export function createNativeDesktopSession({ connect, context, schedule = setTimeout, unschedule = clearTimeout }) {
  let socket, pending, rejectPending, timer, leaseOwner;
  let state = { phase: "closed", error: "" };
  const listeners = new Set();
  const change = (phase, error = "") => {
    state = { phase, error };
    for (const listener of listeners) listener();
  };
  function close(error = "") {
    const current = socket;
    socket = null;
    unschedule(timer);
    const reject = rejectPending;
    pending = rejectPending = null;
    if (current) current.close();
    change("closed", error);
    reject?.(new Error(error || "已取消打开桌面"));
  }
  return {
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    snapshot: () => state,
    close,
    open() {
      const owner = context();
      if (socket && owner.connection_id !== leaseOwner?.connection_id) close("工作环境已切换，请重新打开桌面。");
      if (owner.mode !== "local") return Promise.reject(new Error("虚拟机启动器仅支持本机虚拟 Mac。"));
      if (state.phase === "open") return Promise.resolve();
      if (pending) return pending;
      leaseOwner = owner;
      change("opening");
      let resolve;
      pending = new Promise((yes, no) => { resolve = yes; rejectPending = no; });
      const result = pending;
      // Register the promise before a socket can synchronously fail.
      try { socket = connect(); }
      catch { close("无法连接虚拟 Mac 的桌面窗口。"); return result; }
      const current = socket;
      timer = schedule(() => { if (socket === current) close("等待桌面窗口超时，请重试。"); }, 12000);
      current.onmessage = event => {
        if (socket !== current) return;
        if (context().connection_id !== owner.connection_id) { close("工作环境已切换，请重新打开桌面。"); return; }
        try {
          const value = JSON.parse(event.data);
          if (value.error) { close(value.error); return; }
          if (value.open === true) {
            unschedule(timer);
            pending = rejectPending = null;
            change("open");
            resolve();
          }
        } catch { close("桌面窗口返回了无效状态。"); }
      };
      current.onerror = () => {
        // The native window's close button ends its lease without a WebSocket
        // close frame. WebKit reports that normal close as an error event.
        if (socket === current) close(state.phase === "opening" ? "无法打开桌面，请确认虚拟 Mac 已启动。" : "");
      };
      current.onclose = () => { if (socket === current) close(); };
      return result;
    },
  };
}

export function launcherCanOpen(status, context) {
  return context.mode === "local" && status?.guest_system === "macos" && !status?.storage_recovery?.required;
}

// The desktop needs a running VZ process, not SSH/browser readiness. The
// existing start job still owns network verification and keeps egress closed.
export async function launchVirtualMachine({ readStatus, start, openDesktop, signal,
  delay = () => new Promise(resolve => setTimeout(resolve, 1000)), now = Date.now, onStatus = () => {} }) {
  const check = () => signal?.throwIfAborted();
  check();
  let status = await readStatus();
  check();
  if (status.job?.running && status.job.kind === "stop") throw new Error("虚拟机正在停止，请完成后重试。");
  const deadline = now() + 120000;
  let job;
  if (!status.vm_running) {
    if (status.job?.running && status.job.kind !== "start") throw new Error("正在处理其他环境操作，请完成后重试。");
    job = status.job?.running ? status.job : await start();
    check();
    if (!job?.id) throw new Error("启动请求未返回任务编号，请先核对虚拟机状态。");
  }
  while (!status.vm_running) {
    check();
    if (now() >= deadline) throw new Error("虚拟机仍未启动，请核对操作详情后重试。");
    await delay(); check();
    status = await readStatus(); check(); onStatus(status);
    if (!status.vm_running && status.job?.id === job.id && !status.job.running)
      throw new Error(status.job.error || "启动任务已结束，但虚拟机尚未运行。");
  }
  // The owner record can appear just before its AppKit socket is listening.
  // Retry only opening a view; never submit another VM start operation.
  let lastError;
  for (let attempt = 0; attempt < 5; attempt++) {
    check();
    try { await openDesktop(); check(); return; }
    catch (error) { check(); lastError = error; }
    if (attempt < 4) { await delay(); check(); }
  }
  throw lastError;
}

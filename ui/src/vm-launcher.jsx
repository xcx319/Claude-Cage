import React, { useEffect, useRef, useState } from "react";
import { ArrowUpRight, LoaderCircle, Monitor, Power, ShieldCheck } from "lucide-react";
import { api, native, nativeAvailable } from "./api";
import { getClientContext } from "./client-context.mjs";
import { nativeDesktop, useNativeDesktopState } from "./native-desktop";
import { launchVirtualMachine, launcherCanOpen } from "./vm-launcher-state.mjs";
import { networkState } from "./safety-state.mjs";
import { Modal } from "./modal";
import logo from "./logo.png";
import "./vm-launcher.css";

export function VMLauncher({ onWorkbench }) {
  const [status, setStatus] = useState(null), [error, setError] = useState("");
  const [connectionError, setConnectionError] = useState("");
  const [opening, setOpening] = useState(false), [submitting, setSubmitting] = useState(false);
  const [dialog, setDialog] = useState("");
  const desktop = useNativeDesktopState();
  const intent = useRef(null), alive = useRef(true), acknowledged = useRef(false);
  useEffect(() => {
    alive.current = true;
    let timer;
    async function poll() {
      try {
        const next = await api("/status");
        if (!alive.current) return;
        setStatus(next); setConnectionError("");
        if (!acknowledged.current && nativeAvailable()) {
          acknowledged.current = await native("workbenchReady");
        }
      } catch (e) { if (alive.current) setConnectionError(e.message); }
      finally { if (alive.current) timer = setTimeout(poll, 1500); }
    }
    void poll();
    return () => { alive.current = false; clearTimeout(timer); intent.current?.abort(); };
  }, []);
  useEffect(() => {
    const handler = command => {
      if (command === "quit") setDialog("quit");
      else if (command === "closeTab") nativeDesktop.close();
      else if (["settings", "openProject", "newTerminal", "newTab"].includes(command)) onWorkbench();
    };
    window.cageWorkbenchAction = handler;
    return () => { if (window.cageWorkbenchAction === handler) delete window.cageWorkbenchAction; };
  }, [onWorkbench]);
  async function launch() {
    if (intent.current) return;
    const controller = new AbortController(); intent.current = controller;
    const cancelOpening = () => { if (nativeDesktop.snapshot().phase === "opening") nativeDesktop.close(); };
    controller.signal.addEventListener("abort", cancelOpening, { once: true });
    setOpening(true); setError("");
    try {
      await launchVirtualMachine({ readStatus: () => api("/status"), start: () => api("/start", {}),
        openDesktop: () => nativeDesktop.open(), signal: controller.signal,
        onStatus: value => { if (alive.current) setStatus(value); } });
    } catch (e) { if (alive.current && !controller.signal.aborted) setError(e.message); }
    finally { controller.signal.removeEventListener("abort", cancelOpening); if (intent.current === controller) { intent.current = null; if (alive.current) setOpening(false); } }
  }
  async function stop() {
    setSubmitting(true); setError("");
    intent.current?.abort(); nativeDesktop.close();
    try { await api("/stop", {}); const next = await api("/status"); if (alive.current) { setStatus(next); setDialog(""); } }
    catch (e) { if (alive.current) setError(e.message); }
    finally { if (alive.current) setSubmitting(false); }
  }
  const running = Boolean(status?.vm_running), busy = Boolean(status?.job?.running);
  const available = launcherCanOpen(status, getClientContext());
  const stopping = busy && status.job.kind === "stop";
  const network = connectionError ? { label: "外网状态待确认" } : networkState(status);
  return <main className="vm-launcher" aria-labelledby="vm-launcher-title">
    <header className="vm-launcher-header"><span><img src={logo} alt="" />Cage</span>
      <button onClick={onWorkbench}>打开工作台<ArrowUpRight size={15} /></button></header>
    <section className="vm-launcher-card">
      <div className="vm-launcher-symbol"><Monitor size={48} strokeWidth={1.3} /></div>
      <p className="vm-launcher-eyebrow">本机虚拟机</p>
      <h1 id="vm-launcher-title">虚拟 Mac 启动器</h1>
      <p className="vm-launcher-intro">直接打开完整 macOS 桌面，在虚拟 Mac 中使用浏览器和应用。</p>
      <dl className="vm-launcher-status">
        <div><dt>虚拟机</dt><dd>{connectionError ? "状态待确认" : stopping ? "正在停止" : running ? "运行中" : busy ? "正在启动" : status ? "已停止" : "正在读取状态"}</dd></div>
        <div><dt>桌面窗口</dt><dd>{desktop.phase === "open" ? "已打开" : desktop.phase === "opening" || opening ? "正在打开" : "已关闭"}</dd></div>
        <div><dt><ShieldCheck size={15} />网络隔离</dt><dd>{network.label}</dd></div>
      </dl>
      <div className="vm-launcher-actions">
        <button className="primary" disabled={!available || Boolean(connectionError) || stopping || opening || desktop.phase === "open" || (!running && busy && status.job.kind !== "start")}
          onClick={() => void launch()}>{opening ? <LoaderCircle size={17} className="spin" /> : <Monitor size={17} />}
          {opening ? "正在启动并打开…" : desktop.phase === "open" ? "桌面已打开" : running ? "打开桌面" : "启动并打开桌面"}</button>
        {desktop.phase !== "closed" && <button onClick={() => { intent.current?.abort(); nativeDesktop.close(); }}>关闭桌面窗口</button>}
        <button disabled={!status || submitting || stopping || !available || (!running && !busy)} onClick={() => setDialog("stop")}><Power size={16} />停止虚拟机</button>
      </div>
      <p className="vm-launcher-note">关闭桌面窗口会保留虚拟机运行。外网访问继续受 Cage 网络隔离控制。</p>
      {!available && status && <p role="alert">此入口仅用于已安装在本机的虚拟 Mac。请在工作台完成环境准备或处理存储恢复。</p>}
      {connectionError || error || desktop.error ? <p className="error-message" role="alert">{connectionError || error || desktop.error}</p> : null}
      {status?.job?.running && <p role="status">{status.job.message || "正在处理环境操作…"}</p>}
      {status?.job?.error && <p className="error-message" role="alert">{status.job.error}</p>}
      <details><summary>运行详情与网络检查</summary><p>{status?.network_error || status?.safety?.error || "网络门槛由后台管理，检查通过前保持关闭。"}</p>
        <ul>{status?.safety?.report?.checks?.map(check => <li key={check.id}>{check.title}：{({ passed: "通过", failed: "失败", unknown: "待确认" })[check.state] || check.state}</li>)}</ul>
        <pre>{status?.job?.log || "暂无操作日志"}</pre></details>
    </section>
    {dialog && <Modal title={dialog === "stop" ? "停止虚拟 Mac？" : "退出虚拟机启动器？"}
      onClose={submitting ? undefined : () => setDialog("")} footer={<>
        <button disabled={submitting} onClick={() => setDialog("")}>取消</button>
        {dialog === "quit" && <button disabled={submitting} onClick={() => { intent.current?.abort(); nativeDesktop.close(); void native("quitNow"); }}>仅退出启动器</button>}
        {dialog === "stop" && <button className="primary" disabled={submitting} onClick={() => void stop()}>{submitting ? "正在提交…" : "已保存，停止虚拟机"}</button>}
      </>}><div className="modal-body"><p>{dialog === "stop" ? "请先保存虚拟 Mac 中的工作。停止会结束运行中的程序和终端，虚拟磁盘、账户和项目数据保留。" : "退出启动器会关闭桌面窗口，虚拟机和后台网络管理继续运行。要停止虚拟机，请先取消并点击“停止虚拟机”。"}</p></div></Modal>}
  </main>;
}

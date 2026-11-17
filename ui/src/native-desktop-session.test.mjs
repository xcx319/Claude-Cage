import test from "node:test";
import assert from "node:assert/strict";
import { createNativeDesktopSession } from "./native-desktop-session.mjs";

function fixture() {
  const sockets = [];
  let owner = { mode: "local", connection_id: "first" }, timeout;
  const session = createNativeDesktopSession({ context: () => owner,
    connect() { const socket = { closed: 0, close() { this.closed++; } }; sockets.push(socket); return socket; },
    schedule: fn => { timeout = fn; return fn; }, unschedule: () => {} });
  const reply = (index, value) => sockets[index].onmessage({ data: JSON.stringify(value) });
  return { session, sockets, reply, expire: () => timeout(), switch: value => { owner = value; } };
}
test("launcher and sidebar share one lease and opening promise", async () => {
  const f = fixture();
  const first = f.session.open(), second = f.session.open();
  assert.equal(first, second); assert.equal(f.sockets.length, 1);
  f.reply(0, { open: true }); await first;
  await f.session.open(); assert.equal(f.sockets.length, 1);
  assert.equal(f.session.snapshot().phase, "open");
  f.session.close(); assert.equal(f.sockets[0].closed, 1);
  assert.equal(f.session.snapshot().phase, "closed");
});
test("failed or canceled leases can retry and stale events cannot close a replacement", async () => {
  const f = fixture(), first = f.session.open();
  f.reply(0, { error: "not running" }); await assert.rejects(first, /not running/);
  const next = f.session.open();
  f.sockets[0].onclose(); assert.equal(f.session.snapshot().phase, "opening");
  f.reply(1, { open: true }); await next;
  f.sockets[0].onerror(); assert.equal(f.session.snapshot().phase, "open");
  f.session.close();
  const third = f.session.open(); f.session.close(); await assert.rejects(third, /取消/);
});
test("native view cannot be opened remotely or acknowledged across connection generations", async () => {
  const f = fixture(); f.switch({ mode: "remote", connection_id: "remote" });
  await assert.rejects(f.session.open(), /本机/); assert.equal(f.sockets.length, 0);
  f.switch({ mode: "local", connection_id: "first" });
  const pending = f.session.open(); f.switch({ mode: "local", connection_id: "second" });
  f.reply(0, { open: true }); await assert.rejects(pending, /切换/);
  assert.equal(f.sockets[0].closed, 1);
});
test("a missing handshake has a bounded lifetime", async () => {
  const f = fixture(), pending = f.session.open(); f.expire();
  await assert.rejects(pending, /超时/); assert.equal(f.sockets[0].closed, 1);
});
test("closing the native window after opening clears the lease without a startup error", async () => {
  const f = fixture(), pending = f.session.open();
  f.reply(0, { open: true }); await pending;
  f.sockets[0].onerror(); f.sockets[0].onclose();
  assert.deepEqual(f.session.snapshot(), { phase: "closed", error: "" });
});

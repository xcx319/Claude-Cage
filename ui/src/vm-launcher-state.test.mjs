import test from "node:test";
import assert from "node:assert/strict";
import { launchVirtualMachine, launcherCanOpen } from "./vm-launcher-state.mjs";

test("native desktop availability does not depend on SSH readiness", () => {
  const status = { guest_system: "macos", vm_running: true, ready: false };
  assert.equal(launcherCanOpen(status, { mode: "local" }), true);
  assert.equal(launcherCanOpen(status, { mode: "remote" }), false);
  assert.equal(launcherCanOpen({ ...status, storage_recovery: { required: true } }, { mode: "local" }), false);
});
test("cold launch starts once and opens as soon as VZ is running, before SSH/browser readiness", async () => {
  let reads = 0, starts = 0, opens = 0;
  await launchVirtualMachine({
    readStatus: async () => ({ vm_running: ++reads > 1, ready: false }),
    start: async () => { starts++; return { id: "start" }; },
    openDesktop: async () => { opens++; }, delay: async () => {},
  });
  assert.deepEqual({ reads, starts, opens }, { reads: 2, starts: 1, opens: 1 });
});
test("running or already starting guests do not submit another start", async () => {
  for (const running of [false, true]) {
    let reads = 0, opens = 0;
    await launchVirtualMachine({
      readStatus: async () => ({ vm_running: running || ++reads > 1, job: { id: "existing", kind: "start", running: true } }),
      start: async () => { assert.fail("duplicate start"); }, openDesktop: async () => { opens++; }, delay: async () => {},
    });
    assert.equal(opens, 1);
  }
});
test("display socket races retry only view opening, never VM mutations", async () => {
  let opens = 0;
  await launchVirtualMachine({ readStatus: async () => ({ vm_running: true }),
    start: async () => { assert.fail("unnecessary start"); }, delay: async () => {},
    openDesktop: async () => { if (++opens < 3) throw new Error("socket not ready"); } });
  assert.equal(opens, 3);
});
test("a failed start is shown without automatic resubmission", async () => {
  let reads = 0, starts = 0;
  await assert.rejects(launchVirtualMachine({ readStatus: async () => ({ vm_running: false,
    job: ++reads > 1 ? { id: "start", running: false, error: "failed" } : {} }),
    start: async () => { starts++; return { id: "start" }; }, openDesktop: async () => assert.fail("opened failed VM"), delay: async () => {},
  }), /failed/);
  assert.equal(starts, 1);
});
test("cancellation prevents late automatic opening without stopping the VM", async () => {
  const controller = new AbortController();
  await assert.rejects(launchVirtualMachine({ readStatus: async () => ({ vm_running: false }),
    signal: controller.signal, start: async () => { controller.abort(); return { id: "start" }; },
    openDesktop: async () => assert.fail("late open"), delay: async () => {},
  }), { name: "AbortError" });
});
test("a stopping VM cannot be reopened", async () => {
  await assert.rejects(launchVirtualMachine({ readStatus: async () => ({ vm_running: true, job: { running: true, kind: "stop" } }),
    start: async () => assert.fail("start during stop"), openDesktop: async () => assert.fail("open during stop"),
  }), /正在停止/);
});

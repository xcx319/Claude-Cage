import test from "node:test";
import assert from "node:assert/strict";
import { createMacWindowInput } from "./macos-window-input.mjs";

function fixture(request) {
  let current = { pid: 23, window: 70, geometry: "geometry-1" }, visible = true;
  const calls = [], errors = [], captured = new Set(), eventWindow = new EventTarget();
  const element = Object.assign(new EventTarget(), {
    getBoundingClientRect: () => ({ left: 20, top: 30, width: 400, height: 300 }),
    setPointerCapture: id => captured.add(id),
    hasPointerCapture: id => captured.has(id),
    releasePointerCapture(id) {
      captured.delete(id);
      element.dispatchEvent(new Event("lostpointercapture"));
    },
  });
  const input = createMacWindowInput({
    element, frame: () => current, active: () => visible,
    request: async (action, fields) => { calls.push({ action, ...fields }); await request?.(action, fields); return { ok: true }; },
    onError: error => errors.push(error), eventWindow,
  });
  input.setKeyboardTarget({ focus() {}, classList: { add() {} } });
  const pointer = (type, fields = {}) => {
    const event = new Event(type, { cancelable: true });
    Object.assign(event, {
      pointerId: 1, button: 0, buttons: type === "pointerup" ? 0 : 1,
      clientX: 120, clientY: 105, detail: 1,
      shiftKey: false, ctrlKey: false, altKey: false, metaKey: false, ...fields,
    });
    element.dispatchEvent(event);
    return event;
  };
  return { input, calls, errors, captured, eventWindow, element, pointer,
    changeTarget: () => { current = { ...current, geometry: "geometry-2" }; },
    hide: () => { visible = false; },
  };
}

test("native window drag preserves down/move/up and coalesces only adjacent moves", async () => {
  const f = fixture();
  let release;
  const gate = f.input.run(() => new Promise(resolve => { release = resolve; }));
  await Promise.resolve();
  try {
    assert.equal(f.pointer("pointerdown").defaultPrevented, true);
    f.pointer("pointermove", { clientX: 180 });
    f.pointer("pointermove", { clientX: 300 });
    f.pointer("pointerdown", { pointerId: 2 });
    f.pointer("pointerup", { clientX: 900, clientY: -40 });
    release();
    await gate;
    await f.input.run(() => {});
    assert.deepEqual(f.calls.map(call => call.phase), ["down", "move", "up"]);
    assert.deepEqual(f.calls.map(call => call.x), [0.25, 0.7, 1 - Number.EPSILON]);
    assert.equal(f.calls[2].y, 0);
    assert(f.calls.every(call => call.pid === 23 && call.window === 70 && call.geometry === "geometry-1"));
    assert.equal(f.captured.size, 0);
    assert.deepEqual(f.errors, []);
  } finally { f.input.dispose(); }
});

test("native window forwards right button, double click and horizontal scroll", async () => {
  const f = fixture();
  try {
    f.pointer("pointerdown", { button: 2, buttons: 2 });
    f.pointer("pointerup", { button: 2 });
    f.pointer("pointerdown", { detail: 2 });
    f.pointer("pointerup", { detail: 2 });
    f.pointer("wheel", { deltaX: 54, deltaY: -2000 });
    await f.input.run(() => {});
    assert.deepEqual(f.calls.slice(0, 4).map(call => [call.phase, call.button, call.clicks]), [
      ["down", 2, 1], ["up", 2, 1], ["down", 0, 2], ["up", 0, 2],
    ]);
    assert.equal(f.calls[4].deltaX, 54);
    assert.equal(f.calls[4].delta, -1200);
    assert.equal(f.pointer("contextmenu").defaultPrevented, true);
  } finally { f.input.dispose(); }
});

test("cancelled pointer capture resets held input before new keys", async () => {
  const f = fixture();
  try {
    f.input.sendKey(0xffeb, "MetaLeft", true);
    f.pointer("pointerdown");
    f.pointer("pointercancel");
    f.input.sendKey(97, "KeyA", true);
    await f.input.run(() => {});
    assert.equal(f.captured.size, 0);
    assert.deepEqual(f.calls.map(call => call.action), ["key", "pointer", "input-reset", "key"]);
    assert.equal(f.calls.at(-1).command, false);
  } finally { f.input.dispose(); }
});

test("queued native paste sends its chord before a following Enter", async () => {
  const f = fixture();
  let release;
  const clipboard = new Promise(resolve => { release = resolve; });
  try {
    const paste = f.input.runKeyAction(async sendKey => {
      await clipboard;
      for (const key of [[0xffeb, "MetaLeft", true], [118, "KeyV", true], [118, "KeyV", false], [0xffeb, "MetaLeft", false]])
        await sendKey(...key);
    });
    f.input.sendKey(0xff0d, "Enter", true);
    f.input.sendKey(0xff0d, "Enter", false);
    await Promise.resolve();
    assert.deepEqual(f.calls, []);
    release();
    await paste;
    await f.input.run(() => {});
    assert.deepEqual(f.calls.map(call => [call.code, call.down]), [
      ["MetaLeft", true], ["KeyV", true], ["KeyV", false], ["MetaLeft", false], ["Enter", true], ["Enter", false],
    ]);
  } finally { f.input.dispose(); }
});

test("a failed paste cancels already queued Enter and recovers for new input", async () => {
  const f = fixture();
  let fail;
  const clipboard = new Promise((_, reject) => { fail = reject; });
  try {
    const paste = f.input.runKeyAction(async () => { await clipboard; });
    f.input.sendKey(0xff0d, "Enter", true);
    const drained = f.input.run(() => {});
    fail(new Error("fixture clipboard failed"));
    await assert.rejects(paste, /fixture clipboard failed/);
    await assert.rejects(drained, /fixture clipboard failed/);
    assert.deepEqual(f.calls.map(call => call.action), ["input-reset"]);
    f.input.sendKey(97, "KeyA", true);
    await f.input.run(() => {});
    assert.equal(f.calls.at(-1).code, "KeyA");
  } finally { f.input.dispose(); }
});

test("a frame change rejects queued input and disposal releases only its connection", async () => {
  const f = fixture();
  let release;
  const gate = f.input.run(() => new Promise(resolve => { release = resolve; }));
  await Promise.resolve();
  f.input.sendKey(97, "KeyA", true);
  const drained = f.input.run(() => {});
  f.changeTarget();
  release();
  await gate;
  await assert.rejects(drained, /输入窗口已变化/);
  assert.deepEqual(f.calls.map(call => call.action), ["input-reset"]);
  f.input.dispose();
  const count = f.calls.length;
  f.pointer("pointerdown");
  f.eventWindow.dispatchEvent(new Event("blur"));
  await assert.rejects(f.input.run(() => {}), /连接已关闭/);
  assert.equal(f.calls.length, count);
});

test("native window merges wheel events queued behind a slow scroll and keeps the excess", async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const calls = [], errors = [];
  const element = Object.assign(new EventTarget(), { getBoundingClientRect: () => ({ left: 0, top: 0, width: 100, height: 100 }) });
  const input = createMacWindowInput({
    element, frame: () => ({ pid: 23, window: 70, geometry: "geometry-1" }), active: () => true,
    request: async (action, fields) => { calls.push({ action, ...fields }); if (calls.length === 1) await gate; return { ok: true }; },
    onError: error => errors.push(error), eventWindow: new EventTarget(),
  });
  const wheel = (deltaY, clientY = 50) => element.dispatchEvent(Object.assign(new Event("wheel", { cancelable: true }), { deltaY, deltaX: 0, clientX: 50, clientY }));
  try {
    wheel(100);
    await new Promise(resolve => setTimeout(resolve));
    for (const delta of [300, 400, 500, 600]) wheel(delta, 60);
    release();
    await input.run(() => {});
    await input.run(() => {});
    assert.deepEqual(calls.map(call => [call.action, call.delta]), [["scroll", 100], ["scroll", 1200], ["scroll", 600]]);
    assert.equal(calls[1].y, 0.6);
    assert.deepEqual(errors, []);
  } finally { input.dispose(); }
});

async function queuedWheels(exercise) {
  const f = fixture();
  let release;
  const gate = f.input.run(() => new Promise(resolve => { release = resolve; }));
  await Promise.resolve();
  const wheel = (y, x = 0, fields = {}) => f.pointer("wheel", { deltaY: y, deltaX: x, ...fields });
  try {
    exercise(f, wheel);
    const drained = f.input.run(() => {});
    release(); await gate; await drained;
    return f.calls.slice();
  } finally { f.input.dispose(); }
}

test("wheel groups conserve full displacement within each request limit", async () => {
  const calls = await queuedWheels((f, wheel) => { wheel(900, 800); wheel(900, 800); wheel(5000, -5000); });
  assert.deepEqual(calls.map(c => [c.delta, c.deltaX]), [[900,800], [900,800], [1200,-1200], [1200,-1200], [1200,-1200], [1200,-1200], [200,-200]]);
});

test("wheel overflow stays before later keys and attachments", async () => {
  const calls = await queuedWheels((f, wheel) => {
    wheel(700); wheel(700);
    f.input.sendKey(97, "KeyA", true);
    wheel(200);
    f.input.run(() => { f.calls.push({ action: "attachment" }); });
    wheel(300);
  });
  assert.deepEqual(calls.map(c => [c.action,c.delta]), [["scroll",700],["scroll",700],["key",undefined],["scroll",200],["attachment",undefined],["scroll",300]]);
});

test("wheel groups never cross direction, coordinate, pointer or blur boundaries", async () => {
  const calls = await queuedWheels((f, wheel) => {
    wheel(100); wheel(-100); wheel(-100,0,{clientX:200});
    f.pointer("pointermove"); wheel(-100,0,{clientX:200});
    f.eventWindow.dispatchEvent(new Event("blur")); wheel(-100,0,{clientX:200});
  });
  assert.deepEqual(calls.map(c => c.action), ["scroll","scroll","scroll","pointer","scroll","input-reset","scroll"]);
  assert.deepEqual(calls.filter(c => c.action === "scroll").map(c => [c.delta,c.x]), [[100,.25],[-100,.25],[-100,.45],[-100,.45],[-100,.45]]);
});

test("wheel geometry changes reject old work and failed scrolls are not retried", async () => {
  await assert.rejects(queuedWheels((f, wheel) => { wheel(100); f.changeTarget(); wheel(100); }), /输入窗口已变化/);
  const failure = new Error("scroll failed");
  const f = fixture(action => { if(action === "scroll") throw failure; });
  f.pointer("wheel", {deltaY:100,deltaX:0});
  await assert.rejects(f.input.run(() => {}), failure);
  assert.deepEqual(f.calls.map(c => c.action), ["scroll","input-reset"]);
  f.input.dispose();
});

test("slow-request wheel burst preserves existing batching without losing displacement", async t => {
  let ticks = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  const f = fixture(async action => { if(action === "scroll") { ticks++; if(ticks === 1) await gate; } });
  f.pointer("wheel", {deltaY:10,deltaX:0});
  await new Promise(resolve => setTimeout(resolve));
  for(let i=0;i<99;i++) f.pointer("wheel", {deltaY:10,deltaX:0});
  const drained = f.input.run(() => {});
  release(); await drained;
  assert.equal(ticks, 2);
  assert.equal(f.calls.reduce((sum,c) => sum+(c.delta||0),0),1000);
  t.diagnostic(JSON.stringify({events:100,requests:ticks,serialized_service_ms_at_100ms_per_request:ticks*100}));
  f.input.dispose();
});

test("disposing a queued wheel batch sends no scroll or retry", async () => {
  const f = fixture();
  let release;
  const gate = f.input.run(() => new Promise(resolve => { release = resolve; }));
  await Promise.resolve();
  f.pointer("wheel", {deltaY:100,deltaX:0});
  const drained = f.input.run(() => {});
  f.input.dispose(); release(); await gate;
  await assert.rejects(drained, /连接已关闭/);
  assert.deepEqual(f.calls.map(c => c.action), ["input-reset"]);
});

test("a 5000 wheel delta is fully delivered before a later key", async () => {
  const calls = await queuedWheels((f, wheel) => { wheel(5000); f.input.sendKey(97,"KeyA",true); });
  assert.deepEqual(calls.map(c => [c.action,c.delta]), [["scroll",1200],["scroll",1200],["scroll",1200],["scroll",1200],["scroll",200],["key",undefined]]);
});

test("oversized wheel admission rejects the entire event without partial delivery", async () => {
  let observed;
  const calls = await queuedWheels((f, wheel) => { observed=f; wheel(1200*129); f.input.sendKey(97,"KeyA",true); });
  assert.deepEqual(calls.map(c => c.action), ["key"]);
  assert.deepEqual(observed.errors, ["窗口输入等待过多，请重新连接"]);
});

test("each split wheel block revalidates geometry before sending", async () => {
  const f = fixture(action => { if(action === "scroll") f.changeTarget(); });
  f.pointer("wheel", {deltaY:5000,deltaX:0});
  await assert.rejects(f.input.run(() => {}), /输入窗口已变化/);
  assert.deepEqual(f.calls.map(c => [c.action,c.delta]), [["scroll",1200],["input-reset",undefined]]);
  f.input.dispose();
});

test("passive hover deduplicates unchanged quantized coordinates until cursor moves or button clicks", async () => {
  const f = fixture();
  try {
    f.pointer("pointermove", { buttons: 0, clientX: 120, clientY: 105 });
    f.pointer("pointermove", { buttons: 0, clientX: 120.001, clientY: 105.001 });
    await f.input.run(() => {});
    assert.equal(f.calls.length, 1);
    f.pointer("pointermove", { buttons: 0, clientX: 140, clientY: 105 });
    await f.input.run(() => {});
    assert.equal(f.calls.length, 2);
    f.pointer("pointerdown", { button: 0, buttons: 1, clientX: 140, clientY: 105 });
    f.pointer("pointerup", { button: 0, buttons: 0, clientX: 140, clientY: 105 });
    f.pointer("pointermove", { buttons: 0, clientX: 140, clientY: 105 });
    await f.input.run(() => {});
    assert.equal(f.calls.length, 5);
  } finally { f.input.dispose(); }

});

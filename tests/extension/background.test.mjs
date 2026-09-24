// Tests for extensions/chromium/background.js against the in-memory Chrome model (run: node --test tests/extension).
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { loadExtension } from "./chrome-mock.mjs";

const PLACEHOLDER = "chrome-extension://testid/placeholder.html";
let ext;
afterEach(() => ext?.stop());

/** Loads the extension, connects the app and returns helpers. */
async function connected(options) {
  ext = loadExtension(options);
  ext.port.receive({ type: "app-connected" });
  await ext.settle();
  return ext;
}

const sent = (type) => ext.port.sent.filter((m) => m.type === type);
const lastState = () => sent("state").at(-1);

async function openWindow() {
  const w = await ext.chrome.windows.create({ focused: true });
  return w.id;
}

/** Creates a titled group with the given URLs in a window (as if made earlier). */
async function makeGroup(windowId, title, urls, color = "blue") {
  const ids = [];
  for (const url of urls) ids.push((await ext.chrome.tabs.create({ windowId, url, active: false })).id);
  const groupId = await ext.chrome.tabs.group({ tabIds: ids, createProperties: { windowId } });
  await ext.chrome.tabGroups.update(groupId, { title, color });
  return { groupId, tabIds: ids };
}

const activate = (title, extra = {}) => ({
  type: "activate", title, color: "blue", defaultUrls: [], label: title, managed: ["a", "b", "c"], create: false, ...extra,
});

// ---------------------------------------------------------------- connection

test("connects to the native host on load and says hello when the app is reachable", async () => {
  await connected({ version: "1.2.3" });
  assert.equal(ext.calls.connectNative, 1);
  assert.equal(ext.port.name, "io.github.herdr_browser_tab_groups");
  assert.deepEqual(sent("hello")[0], { type: "hello", version: "1.2.3" });
});

test("sends nothing and shows 'off' while the app is disconnected", async () => {
  await connected();
  ext.port.receive({ type: "app-disconnected" });
  await ext.settle();
  assert.equal(ext.badge.text, "off");
  const before = ext.port.sent.length;
  await openWindow();
  await ext.settle();
  assert.equal(ext.port.sent.length, before, "no state reports while the app is down");
});

test("reconnects after the host goes away and explains a missing host in the badge", async () => {
  await connected();
  ext.port.disconnect("Specified native messaging host not found.");
  assert.match(ext.badge.title, /native host not installed/);
  await ext.settle();
  assert.equal(ext.calls.connectNative, 2, "reconnect attempt scheduled");
});

test("reload message reloads the extension", async () => {
  await connected();
  ext.port.receive({ type: "reload" });
  await ext.settle();
  assert.equal(ext.calls.reload, 1);
});

// ---------------------------------------------------------------- activate (space switch / open group)

test("switching to a space without a group leaves Chrome untouched, even with no window", async () => {
  await connected();
  ext.port.receive(activate("a"));
  await ext.settle();
  assert.equal(ext.windows.size, 0, "no window created");
  assert.equal(ext.tabs.size, 0);
});

test("switching to a space without a group in an open window changes nothing", async () => {
  await connected();
  const w = await openWindow();
  const { groupId } = await makeGroup(w, "b", ["http://b/"]);
  const tabsBefore = JSON.stringify([...ext.tabs.values()]);
  ext.port.receive(activate("a"));
  await ext.settle();
  assert.equal(JSON.stringify([...ext.tabs.values()]), tabsBefore);
  assert.equal(ext.groups.get(groupId).collapsed, false, "other groups aren't collapsed either");
  assert.equal(ext.badge.text, "–", "badge: no group for this space");
});

test("switching shows the space's group on its last used tab and collapses other managed groups only", async () => {
  await connected();
  const w = await openWindow();
  const a = await makeGroup(w, "a", ["http://a/1", "http://a/2"]);
  const b = await makeGroup(w, "b", ["http://b/"]);
  const mine = await makeGroup(w, "personal", ["http://mail/"]);
  await ext.chrome.tabs.update(a.tabIds[1], { active: true }); // remembered as last used in "a"
  await ext.settle();
  await ext.chrome.tabs.update(b.tabIds[0], { active: true });
  await ext.settle();

  ext.port.receive(activate("a"));
  await ext.settle();
  assert.equal(ext.tabs.get(a.tabIds[1]).active, true, "last used tab of the group is active again");
  assert.equal(ext.groups.get(a.groupId).collapsed, false);
  assert.equal(ext.groups.get(b.groupId).collapsed, true, "other managed group collapsed");
  assert.equal(ext.groups.get(mine.groupId).collapsed, false, "unmanaged group untouched");
  assert.equal(lastState().activeGroup, "a");
  assert.equal(ext.badge.text, "a");
});

test("open group with no Chrome window: opens a focused window, removes the blank tab, reports it", async () => {
  await connected();
  ext.port.receive(activate("a", { create: true, id: "r1", label: "myapp-a" }));
  await ext.settle();
  assert.equal(ext.windows.size, 1);
  const win = [...ext.windows.values()][0];
  assert.equal(win.focused, true, "new window comes to the front");
  const tabs = ext.tabsIn(win.id);
  assert.equal(tabs.length, 1, "blank New Tab removed");
  assert.ok(tabs[0].url.startsWith(PLACEHOLDER), "placeholder page explains how to add URLs");
  assert.equal(ext.groups.size, 1);
  assert.equal([...ext.groups.values()][0].title, "a");
  assert.deepEqual(sent("result").at(-1), { type: "result", id: "r1", ok: true, createdWindow: true });
});

test("a tab that vanishes before its activation event is processed doesn't break state reporting", async () => {
  await connected();
  const errors = [];
  const orig = console.error;
  console.error = (...args) => errors.push(args.join(" "));
  try {
    ext.port.receive(activate("a", { create: true, id: "r9" })); // opens a window, then removes its blank tab
    await ext.settle();
  } finally {
    console.error = orig;
  }
  assert.deepEqual(errors, []);
  assert.equal(lastState().activeGroup, "a");
});

test("open group uses the configured default URLs and replies without createdWindow", async () => {
  await connected();
  const w = await openWindow();
  ext.port.receive(activate("a", { create: true, id: "r2", defaultUrls: ["http://localhost:8001/", "http://localhost:8001/admin"] }));
  await ext.settle();
  const group = [...ext.groups.values()].find((g) => g.title === "a");
  const urls = ext.tabsIn(w).filter((t) => t.groupId === group.id).map((t) => t.url);
  assert.deepEqual(urls, ["http://localhost:8001/", "http://localhost:8001/admin"]);
  assert.deepEqual(sent("result").at(-1), { type: "result", id: "r2", ok: true, createdWindow: false });
});

test("open group of an existing group just shows it", async () => {
  await connected();
  const w = await openWindow();
  const a = await makeGroup(w, "a", ["http://a/"]);
  ext.port.receive(activate("a", { create: true, id: "r3" }));
  await ext.settle();
  assert.equal(ext.groups.size, 1, "no second group");
  assert.equal(ext.tabs.get(a.tabIds[0]).active, true);
  assert.equal(sent("result").at(-1).ok, true);
});

test("the group color follows the app", async () => {
  await connected();
  const w = await openWindow();
  const a = await makeGroup(w, "a", ["http://a/"], "grey");
  ext.port.receive(activate("a", { color: "purple" }));
  await ext.settle();
  assert.equal(ext.groups.get(a.groupId).color, "purple");
});

// ---------------------------------------------------------------- open URL (hbtg open)

const openUrl = (url, extra = {}) => ({ type: "open", id: "o1", title: "a", color: "blue", url, label: "a", activeTitle: "a", ...extra });

test("open URL creates the group and activates the tab when the space is visible", async () => {
  await connected();
  await openWindow();
  ext.port.receive(openUrl("http://localhost:8001/"));
  await ext.settle();
  const tab = [...ext.tabs.values()].find((t) => t.url === "http://localhost:8001/");
  assert.ok(tab && tab.active);
  assert.equal(ext.groups.get(tab.groupId).title, "a");
  assert.deepEqual(sent("result").at(-1), { type: "result", id: "o1", ok: true, reused: false, createdWindow: false });
});

test("open URL for a background space keeps its new group collapsed", async () => {
  await connected();
  const w = await openWindow();
  const visible = await makeGroup(w, "b", ["http://b/"]);
  await ext.chrome.tabs.update(visible.tabIds[0], { active: true });
  ext.port.receive(openUrl("http://localhost:8002/", { activeTitle: "b" }));
  await ext.settle();
  const tab = [...ext.tabs.values()].find((t) => t.url === "http://localhost:8002/");
  assert.equal(tab.active, false, "the visible space's tab stays active");
  assert.equal(ext.groups.get(tab.groupId).collapsed, true);
});

test("open URL reuses a tab with the same origin and path and replaces the placeholder", async () => {
  await connected();
  const w = await openWindow();
  const a = await makeGroup(w, "a", [`${PLACEHOLDER}?title=a`, "http://localhost:8001/login?x=1"]);
  ext.port.receive(openUrl("http://localhost:8001/login?next=/home"));
  await ext.settle();
  assert.equal(ext.tabs.get(a.tabIds[1]).url, "http://localhost:8001/login?next=/home");
  assert.equal(sent("result").at(-1).reused, true);

  ext.port.receive(openUrl("http://localhost:8001/other", { id: "o2" }));
  await ext.settle();
  assert.equal(ext.tabs.get(a.tabIds[0]).url, "http://localhost:8001/other", "placeholder tab reused");
  ext.port.receive(openUrl("http://localhost:9999/", { id: "o3" }));
  await ext.settle();
  const added = [...ext.tabs.values()].find((t) => t.url === "http://localhost:9999/");
  assert.equal(added.groupId, a.groupId, "new tab joins the existing group");
});

test("open URL errors are reported back", async () => {
  await connected();
  const w = await openWindow();
  await makeGroup(w, "a", ["http://a/"]);
  ext.chrome.tabs.create = async () => { throw new Error("boom"); };
  ext.port.receive(openUrl("http://new/"));
  await ext.settle();
  assert.deepEqual(sent("result").at(-1), { type: "result", id: "o1", ok: false, error: "boom" });
});

// ---------------------------------------------------------------- close / rename / place

test("close removes all tabs of the group and reports how many", async () => {
  await connected();
  const w = await openWindow();
  ext.port.receive(activate("a", { create: true, id: "r" })); // makes w the managed window
  await ext.settle();
  const a = [...ext.groups.values()].find((g) => g.title === "a");
  await makeGroup(w, "b", ["http://b/"]);
  ext.port.receive({ type: "close", title: "a", id: "c1" });
  await ext.settle();
  assert.equal([...ext.groups.values()].some((g) => g.id === a.id), false);
  assert.deepEqual(sent("result").at(-1), { type: "result", id: "c1", ok: true, createdWindow: false, closed: 1 });
  assert.ok([...ext.groups.values()].some((g) => g.title === "b"), "other groups stay");
});

test("close never touches a same-named group outside the managed window", async () => {
  await connected();
  const managed = await openWindow();
  ext.port.receive(activate("x", { create: true, id: "r" }));
  await ext.settle();
  const other = await openWindow();
  const mine = await makeGroup(other, "a", ["http://my-own-tab/"]);
  ext.port.receive({ type: "close", title: "a", id: "c2" });
  await ext.settle();
  assert.ok(ext.groups.has(mine.groupId), "hand-made group in another window survives");
  assert.equal(sent("result").at(-1).closed, 0);
  assert.ok(managed);
});

test("close without a managed window reports nothing to close", async () => {
  await connected();
  ext.port.receive({ type: "close", title: "a", id: "c3" });
  await ext.settle();
  assert.equal(sent("result").at(-1).closed, 0);
});

test("rename renames the group in the managed window", async () => {
  await connected();
  await openWindow();
  ext.port.receive(activate("old", { create: true, id: "r" }));
  await ext.settle();
  ext.port.receive({ type: "rename", from: "old", to: "new", color: "red" });
  await ext.settle();
  const g = [...ext.groups.values()][0];
  assert.equal(g.title, "new");
  assert.equal(g.color, "red");
});

test("place moves the managed window, restoring it from maximized first", async () => {
  await connected();
  const w = await openWindow();
  ext.windows.get(w).state = "maximized";
  ext.port.receive(activate("a", { create: true, id: "r" }));
  await ext.settle();
  ext.port.receive({ type: "place", left: 10, top: 20, width: 300, height: 400 });
  await ext.settle();
  const win = ext.windows.get(w);
  assert.deepEqual([win.state, win.left, win.top, win.width, win.height], ["normal", 10, 20, 300, 400]);
});

// ---------------------------------------------------------------- state reports and badge

test("reports the active group and all groups, and flags a mismatch in the badge", async () => {
  await connected();
  const w = await openWindow();
  ext.port.receive(activate("a", { create: true, id: "r" }));
  await ext.settle();
  const b = await makeGroup(w, "b", ["http://b/"]);
  await ext.chrome.tabs.update(b.tabIds[0], { active: true }); // user clicks a tab of another space
  await ext.settle();
  assert.equal(lastState().activeGroup, "b");
  assert.deepEqual([...lastState().groups].sort(), ["a", "b"]);
  assert.equal(ext.badge.text, "!", "herdr is on 'a' but Chrome shows 'b'");
});

test("if the managed window is closed, the window holding most herdr groups takes over", async () => {
  await connected();
  const first = await openWindow();
  ext.port.receive(activate("a", { create: true, id: "r" })); // first becomes the managed window
  await ext.settle();
  const w2 = await openWindow();
  await makeGroup(w2, "b", ["http://b/"]);
  await makeGroup(w2, "c", ["http://c/"]);
  const w3 = await openWindow(); // focused, but holds no herdr groups
  ext.windows.get(first) && (await ext.chrome.tabs.remove(ext.tabsIn(first).map((t) => t.id))); // closes it
  ext.port.receive(activate("a", { create: true, id: "r2" }));
  await ext.settle();
  const a = [...ext.groups.values()].find((g) => g.title === "a");
  assert.equal(a.windowId, w2, "group recreated where the other herdr groups are");
  assert.ok(w3);
});

// herdr Browser Tab Groups service worker: talks to HerdrBrowserTabGroups.app through the `hbtg` native
// messaging host and keeps the Chrome "dev window" showing the tab group of the focused herdr workspace.
//
// Native messaging (instead of a direct WebSocket) means Chrome never logs connection errors while the
// app isn't running: the host stays connected and reports app availability.

const NATIVE_HOST = "io.github.herdr_browser_tab_groups";
const PLACEHOLDER = chrome.runtime.getURL("placeholder.html");
const COLOR_HEX = {
  grey: "#5f6368", blue: "#1a73e8", red: "#d93025", yellow: "#e37400", green: "#188038",
  pink: "#d01884", purple: "#9334e6", cyan: "#007b83", orange: "#fa903e",
};

let port = null;          // native messaging port to the hbtg host
let appConnected = false; // host reports whether the app itself is reachable
let backoff = 1000;
let reconnectTimer = null;

// ---------------------------------------------------------------- persistence
// storage.session survives service-worker restarts (not browser restarts, where
// window/tab ids change anyway).

async function session() {
  const s = await chrome.storage.session.get(["devWindowId", "managed", "desired", "lastActive"]);
  return {
    devWindowId: s.devWindowId ?? null,
    managed: new Set(s.managed ?? []),
    desired: s.desired ?? null, // title the app wants visible
    lastActive: s.lastActive ?? {}, // title -> tabId
  };
}

const saveSession = (patch) => chrome.storage.session.set(patch);

// ---------------------------------------------------------------- connection

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(NATIVE_HOST);
  } catch {
    port = null;
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener((msg) => {
    if (msg?.type === "app-connected") {
      appConnected = true;
      backoff = 1000;
      send({ type: "hello", version: chrome.runtime.getManifest().version });
      enqueue(reportState);
    } else if (msg?.type === "app-disconnected") {
      appConnected = false;
      setBadge("off", COLOR_HEX.grey, "herdr Browser Tab Groups app is not running");
    } else if (msg?.type) {
      enqueue(() => handle(msg));
    }
  });
  port.onDisconnect.addListener(() => {
    // Reading lastError marks it handled, so Chrome doesn't log "Unchecked runtime.lastError".
    const error = chrome.runtime.lastError?.message || "";
    port = null;
    appConnected = false;
    setBadge("off", COLOR_HEX.grey, /not found|forbidden/i.test(error)
      ? "hbtg native host not installed — run scripts/bundle-app.sh"
      : "herdr Browser Tab Groups app is not running");
    scheduleReconnect();
  });
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(connect, backoff);
  backoff = Math.min(backoff * 2, 60000);
}

function send(obj) {
  if (port && appConnected) port.postMessage(obj);
}

// Commands run strictly one after another so rapid workspace switching can't interleave.
let chain = Promise.resolve();
function enqueue(fn) {
  chain = chain.then(fn).catch((err) => console.error("hbtg:", err));
  return chain;
}

// Tab-strip edits fail while the user drags a tab; retry briefly.
async function retry(fn, attempts = 5) {
  for (let i = 0; ; i++) {
    try { return await fn(); } catch (err) {
      if (i >= attempts - 1 || !/cannot be edited right now/i.test(String(err))) throw err;
      await new Promise((r) => setTimeout(r, 200));
    }
  }
}

// ---------------------------------------------------------------- windows & groups

// Set when devWindow() had to open a new window; the caller reports it (and removes its blank tab).
let createdWindow = null; // { id, blankTabId }

async function devWindow({ create = true, focus = false } = {}) {
  const s = await session();
  if (s.devWindowId != null) {
    try {
      const w = await chrome.windows.get(s.devWindowId);
      if (w.type === "normal") return w.id;
    } catch { /* window closed */ }
  }
  // Prefer the window that already holds most managed groups.
  const counts = new Map();
  for (const g of await chrome.tabGroups.query({})) {
    if (s.managed.has(g.title)) counts.set(g.windowId, (counts.get(g.windowId) || 0) + 1);
  }
  let id = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
  if (id == null) {
    const wins = (await chrome.windows.getAll({ windowTypes: ["normal"] })).filter((w) => !w.incognito);
    id = (wins.find((w) => w.focused) || wins[0])?.id ?? null;
  }
  if (id == null) {
    if (!create) return null;
    // An explicit "open" brings the new window to the front so it isn't missed behind other apps.
    const w = await chrome.windows.create({ focused: focus });
    id = w.id;
    createdWindow = { id, blankTabId: w.tabs?.[0]?.id ?? null };
  }
  await saveSession({ devWindowId: id });
  return id;
}

// The window we manage, without falling back to another window. Destructive actions (close, rename)
// use this so they can never touch a same-named group the user made in some other window.
async function knownDevWindow() {
  const { devWindowId } = await session();
  if (devWindowId == null) return null;
  try { return (await chrome.windows.get(devWindowId)).id; } catch { return null; }
}

async function findGroup(windowId, title) {
  return (await chrome.tabGroups.query({ windowId })).find((g) => g.title === title) || null;
}

function placeholderUrl(title, label, color) {
  return `${PLACEHOLDER}?${new URLSearchParams({ title, label, color })}`;
}

const isPlaceholder = (url) => (url || "").startsWith(PLACEHOLDER);
const tabUrl = (t) => t.url || t.pendingUrl || "";

async function collapseManaged(windowId, managedTitles, exceptGroupId = null) {
  const managedSet = new Set(managedTitles);
  for (const g of await chrome.tabGroups.query({ windowId })) {
    if (g.id !== exceptGroupId && managedSet.has(g.title) && !g.collapsed) {
      await retry(() => chrome.tabGroups.update(g.id, { collapsed: true }));
    }
  }
}

async function createGroup(windowId, title, color, urls) {
  const tabIds = [];
  for (const url of urls) {
    tabIds.push((await chrome.tabs.create({ windowId, url, active: false })).id);
  }
  const groupId = await retry(() => chrome.tabs.group({ tabIds, createProperties: { windowId } }));
  await retry(() => chrome.tabGroups.update(groupId, { title, color, collapsed: false }));
  // A window we just opened starts with an empty "New Tab"; the group replaces it.
  if (createdWindow?.id === windowId && createdWindow.blankTabId != null) {
    await chrome.tabs.update(tabIds[0], { active: true });
    await chrome.tabs.remove(createdWindow.blankTabId).catch(() => {});
    createdWindow.blankTabId = null;
  }
  return groupId;
}

// Reply to a request that carries an id (explicit open/close from herdr or the CLI).
function reply(id, result) {
  if (id) send({ type: "result", id, ok: true, createdWindow: false, ...result });
}

// Same app page = same origin + path; query/hash may differ.
function sameTarget(a, b) {
  try {
    const x = new URL(a), y = new URL(b);
    const path = (u) => u.pathname.replace(/\/+$/, "") || "/";
    return x.origin === y.origin && path(x) === path(y);
  } catch { return false; }
}

// ---------------------------------------------------------------- commands

async function handle(msg) {
  switch (msg.type) {
    case "activate": return activate(msg);
    case "open": return open(msg);
    case "rename": return rename(msg);
    case "close": return closeGroup(msg);
    case "place": return place(msg);
    // Unpacked extensions don't pick up new code on their own; the app asks after an install.
    case "reload": return chrome.runtime.reload();
  }
}

async function activate(msg) {
  try {
    await activateGroup(msg);
  } catch (err) {
    if (msg.id) send({ type: "result", id: msg.id, ok: false, error: String(err?.message || err) });
    else throw err;
  }
}

async function activateGroup({ title, color, defaultUrls, label, managed, create, id }) {
  await saveSession({ managed, desired: title });
  createdWindow = null;
  // Only an explicit open may create a window; switching spaces never touches a Chrome without windows.
  const windowId = await devWindow({ create: !!create, focus: !!create });
  const group = windowId == null ? null : await findGroup(windowId, title);
  if (!group && !create) {
    // Focusing a space without a group leaves Chrome untouched; only "Open browser group" creates one.
    await reportState();
    return;
  }
  const groupId = group
    ? group.id
    : await createGroup(windowId, title, color,
        defaultUrls?.length ? defaultUrls : [placeholderUrl(title, label, color)]);
  if (group && group.color !== color) await retry(() => chrome.tabGroups.update(groupId, { color }));

  // Activate a tab inside the target first: Chrome refuses to collapse the group holding the active tab.
  const tabs = await chrome.tabs.query({ windowId, groupId });
  const { lastActive } = await session();
  const tab = tabs.find((t) => t.id === lastActive[title]) || tabs.find((t) => t.active) || tabs[0];
  if (tab && !tab.active) await retry(() => chrome.tabs.update(tab.id, { active: true }));
  await retry(() => chrome.tabGroups.update(groupId, { collapsed: false }));
  await collapseManaged(windowId, managed, groupId);
  await reportState();
  reply(id, { createdWindow: createdWindow?.id === windowId });
}

async function closeGroup({ title, id }) {
  const s = await session();
  const windowId = await knownDevWindow();
  const group = windowId == null ? null : await findGroup(windowId, title);
  if (!group) return reply(id, { closed: 0 });
  const tabs = await chrome.tabs.query({ windowId, groupId: group.id });
  if (tabs.length) await chrome.tabs.remove(tabs.map((t) => t.id));
  reply(id, { closed: tabs.length });
  const lastActive = { ...s.lastActive };
  delete lastActive[title];
  await saveSession({ lastActive });
  await reportState();
}

async function open({ id, title, color, url, label, activeTitle }) {
  try {
    createdWindow = null;
    const windowId = await devWindow();
    const visible = activeTitle === title;
    let group = await findGroup(windowId, title);
    let tabId, reused = false;

    if (!group) {
      const groupId = await createGroup(windowId, title, color, [url]);
      tabId = (await chrome.tabs.query({ windowId, groupId }))[0].id;
      // Don't let a background agent expand its group over the one you're looking at.
      if (!visible) await retry(() => chrome.tabGroups.update(groupId, { collapsed: true }));
    } else {
      const tabs = await chrome.tabs.query({ windowId, groupId: group.id });
      const match = tabs.find((t) => sameTarget(tabUrl(t), url));
      const placeholder = tabs.find((t) => isPlaceholder(tabUrl(t)));
      if (match) {
        await chrome.tabs.update(match.id, { url });
        tabId = match.id;
        reused = true;
      } else if (placeholder) {
        await chrome.tabs.update(placeholder.id, { url });
        tabId = placeholder.id;
      } else {
        const last = tabs[tabs.length - 1];
        const tab = await chrome.tabs.create({ windowId, url, active: false, index: last ? last.index + 1 : undefined });
        await retry(() => chrome.tabs.group({ groupId: group.id, tabIds: [tab.id] }));
        tabId = tab.id;
      }
    }

    if (visible) {
      await retry(() => chrome.tabs.update(tabId, { active: true }));
    } else {
      const { lastActive } = await session();
      await saveSession({ lastActive: { ...lastActive, [title]: tabId } });
    }
    send({ type: "result", id, ok: true, reused, createdWindow: createdWindow?.id === windowId });
  } catch (err) {
    send({ type: "result", id, ok: false, error: String(err?.message || err) });
  }
}

async function rename({ from, to, color }) {
  const s = await session();
  const windowId = await knownDevWindow();
  if (windowId == null) return;
  const group = await findGroup(windowId, from);
  if (group) await retry(() => chrome.tabGroups.update(group.id, { title: to, color }));
  const lastActive = { ...s.lastActive };
  if (from in lastActive) { lastActive[to] = lastActive[from]; delete lastActive[from]; }
  await saveSession({
    lastActive,
    managed: [...s.managed].map((t) => (t === from ? to : t)),
    desired: s.desired === from ? to : s.desired,
  });
  await reportState();
}

async function place({ left, top, width, height }) {
  const windowId = await devWindow();
  const w = await chrome.windows.get(windowId);
  if (w.state !== "normal") await chrome.windows.update(windowId, { state: "normal" });
  await chrome.windows.update(windowId, { left, top, width, height });
}

// ---------------------------------------------------------------- state & badge

async function reportState() {
  const windowId = await devWindow({ create: false });
  if (windowId == null) return;
  const [tab] = await chrome.tabs.query({ windowId, active: true });
  let group = null;
  if (tab && tab.groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE) {
    try { group = await chrome.tabGroups.get(tab.groupId); } catch { /* group just closed */ }
  }
  const actual = group?.title ?? null;
  const groups = (await chrome.tabGroups.query({ windowId })).map((g) => g.title);
  send({ type: "state", activeGroup: actual, groups });

  const { desired } = await session();
  if (!appConnected) return;
  if (desired && !groups.includes(desired)) {
    setBadge("–", COLOR_HEX.grey, `No browser group for "${desired}" yet`);
  } else if (desired && actual !== desired) {
    setBadge("!", COLOR_HEX.red, `Showing "${actual ?? "ungrouped"}" but herdr is on "${desired}"`);
  } else if (actual) {
    setBadge(actual.slice(0, 4), COLOR_HEX[group.color] || COLOR_HEX.grey, `herdr workspace: ${actual}`);
  } else {
    setBadge("", COLOR_HEX.grey, "herdr Browser Tab Groups");
  }
}

function setBadge(text, color, title) {
  chrome.action.setBadgeText({ text });
  chrome.action.setBadgeBackgroundColor({ color });
  chrome.action.setBadgeTextColor?.({ color: "#ffffff" });
  chrome.action.setTitle({ title });
}

// ---------------------------------------------------------------- listeners

chrome.tabs.onActivated.addListener(({ tabId, windowId }) => enqueue(async () => {
  const s = await session();
  if (windowId !== s.devWindowId) return;
  // The tab (or its group) may already be gone by the time this queued event runs, e.g. the blank tab of
  // a window we just opened; then there's nothing to remember, only the state to report.
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (tab && tab.groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE) {
    const group = await chrome.tabGroups.get(tab.groupId).catch(() => null);
    if (group) await saveSession({ lastActive: { ...s.lastActive, [group.title]: tabId } });
  }
  await reportState();
}));

// Tab dragged in/out of a group, or group renamed by hand.
chrome.tabs.onUpdated.addListener((_id, change, tab) => {
  if ("groupId" in change && tab.active) enqueue(reportState);
});
chrome.tabGroups.onUpdated.addListener(() => enqueue(reportState));
chrome.tabGroups.onCreated.addListener(() => enqueue(reportState));
chrome.tabGroups.onRemoved.addListener(() => enqueue(reportState));

chrome.windows.onRemoved.addListener(async (windowId) => {
  const { devWindowId } = await session();
  if (windowId === devWindowId) await saveSession({ devWindowId: null });
});

// Clicking the toolbar icon re-syncs to herdr's focused workspace.
chrome.action.onClicked.addListener(() => {
  if (appConnected) send({ type: "hello", version: chrome.runtime.getManifest().version });
  else { backoff = 1000; connect(); }
});

chrome.alarms.create("hbtg-keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => connect());
chrome.runtime.onStartup.addListener(() => connect());
chrome.runtime.onInstalled.addListener(() => connect());
connect();

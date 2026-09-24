// In-memory model of the Chrome extension APIs used by extensions/chromium/background.js.
// Behaves like Chrome where the extension depends on it:
// - new windows start with one blank tab;
// - a group disappears with its last tab;
// - a group that holds the active tab can't be collapsed (Chrome refuses; the extension must activate first).

import { readFileSync } from "node:fs";
import vm from "node:vm";

function event() {
  const listeners = [];
  return {
    addListener: (fn) => listeners.push(fn),
    emit: (...args) => listeners.map((fn) => fn(...args)),
    listeners,
  };
}

export function createChrome({ version = "9.9.9" } = {}) {
  let nextId = 100;
  const windows = new Map(); // id → window
  const tabs = new Map(); // id → tab
  const groups = new Map(); // id → group
  const session = {};
  const local = {};
  const badge = { text: "", color: null, title: "" };
  const ports = [];
  const calls = { reload: 0, connectNative: 0 };

  const tabsIn = (windowId) =>
    [...tabs.values()].filter((t) => t.windowId === windowId).sort((a, b) => a.index - b.index);
  const reindex = (windowId) => tabsIn(windowId).forEach((t, i) => { t.index = i; });
  const copy = (o) => (o ? structuredClone(o) : o);

  const tabsApi = {
    onActivated: event(),
    onUpdated: event(),
    async create({ windowId, url = "chrome://newtab/", active = true, index }) {
      if (!windows.has(windowId)) throw new Error(`No window with id: ${windowId}.`);
      const tab = { id: nextId++, windowId, url, active: false, groupId: -1, index: index ?? tabsIn(windowId).length };
      for (const t of tabsIn(windowId)) if (t.index >= tab.index) t.index++;
      tabs.set(tab.id, tab);
      reindex(windowId);
      if (active) await tabsApi.update(tab.id, { active: true });
      return copy(tab);
    },
    async get(id) {
      if (!tabs.has(id)) throw new Error(`No tab with id: ${id}.`);
      return copy(tabs.get(id));
    },
    async query({ windowId, groupId, active } = {}) {
      return [...tabs.values()]
        .filter((t) => (windowId === undefined || t.windowId === windowId)
          && (groupId === undefined || t.groupId === groupId)
          && (active === undefined || t.active === active))
        .sort((a, b) => a.windowId - b.windowId || a.index - b.index)
        .map(copy);
    },
    async update(id, props) {
      const tab = tabs.get(id);
      if (!tab) throw new Error(`No tab with id: ${id}.`);
      if (props.url !== undefined) tab.url = props.url;
      if (props.active) {
        for (const t of tabsIn(tab.windowId)) t.active = t.id === id;
        // Activating a tab inside a collapsed group expands it, as in Chrome.
        if (tab.groupId !== -1) groups.get(tab.groupId).collapsed = false;
        tabsApi.onActivated.emit({ tabId: id, windowId: tab.windowId });
      }
      return copy(tab);
    },
    async remove(ids) {
      for (const id of [].concat(ids)) {
        const tab = tabs.get(id);
        if (!tab) continue;
        tabs.delete(id);
        reindex(tab.windowId);
        const rest = tabsIn(tab.windowId);
        if (tab.active && rest.length) rest[Math.min(tab.index, rest.length - 1)].active = true;
        if (tab.groupId !== -1 && ![...tabs.values()].some((t) => t.groupId === tab.groupId)) {
          groups.delete(tab.groupId);
          tabGroupsApi.onRemoved.emit({ id: tab.groupId });
        }
        if (!rest.length) windowsApi._close(tab.windowId);
      }
    },
    async group({ tabIds, groupId, createProperties }) {
      let id = groupId;
      if (id === undefined) {
        id = nextId++;
        const windowId = createProperties?.windowId ?? tabs.get(tabIds[0]).windowId;
        groups.set(id, { id, windowId, title: "", color: "grey", collapsed: false });
        tabGroupsApi.onCreated.emit(copy(groups.get(id)));
      }
      for (const tabId of tabIds) {
        const tab = tabs.get(tabId);
        const change = { groupId: id };
        tab.groupId = id;
        tabsApi.onUpdated.emit(tabId, change, copy(tab));
      }
      return id;
    },
  };

  const tabGroupsApi = {
    TAB_GROUP_ID_NONE: -1,
    onUpdated: event(),
    onCreated: event(),
    onRemoved: event(),
    async query({ windowId, title } = {}) {
      return [...groups.values()]
        .filter((g) => (windowId === undefined || g.windowId === windowId) && (title === undefined || g.title === title))
        .map(copy);
    },
    async get(id) {
      if (!groups.has(id)) throw new Error(`No group with id: ${id}.`);
      return copy(groups.get(id));
    },
    async update(id, props) {
      const group = groups.get(id);
      if (!group) throw new Error(`No group with id: ${id}.`);
      if (props.collapsed && [...tabs.values()].some((t) => t.groupId === id && t.active)) {
        throw new Error("Cannot collapse a group that contains the active tab (test model).");
      }
      Object.assign(group, props);
      tabGroupsApi.onUpdated.emit(copy(group));
      return copy(group);
    },
  };

  const windowsApi = {
    onRemoved: event(),
    async get(id) {
      if (!windows.has(id)) throw new Error(`No window with id: ${id}.`);
      return copy(windows.get(id));
    },
    async getAll({ windowTypes } = {}) {
      return [...windows.values()].filter((w) => !windowTypes || windowTypes.includes(w.type)).map(copy);
    },
    async create({ focused = true } = {}) {
      const w = { id: nextId++, type: "normal", incognito: false, focused, state: "normal", left: 0, top: 0, width: 800, height: 600 };
      if (focused) for (const o of windows.values()) o.focused = false;
      windows.set(w.id, w);
      await tabsApi.create({ windowId: w.id, url: "chrome://newtab/", active: true });
      return { ...copy(w), tabs: tabsIn(w.id).map(copy) };
    },
    async update(id, props) {
      Object.assign(windows.get(id), props);
      return copy(windows.get(id));
    },
    _close(id) {
      if (!windows.delete(id)) return;
      for (const t of [...tabs.values()]) if (t.windowId === id) tabs.delete(t.id);
      for (const g of [...groups.values()]) if (g.windowId === id) groups.delete(g.id);
      windowsApi.onRemoved.emit(id);
    },
  };

  function storageArea(store) {
    return {
      async get(keys) {
        const list = keys == null ? Object.keys(store) : [].concat(keys);
        return Object.fromEntries(list.filter((k) => k in store).map((k) => [k, structuredClone(store[k])]));
      },
      async set(obj) { Object.assign(store, structuredClone(obj)); },
    };
  }

  const runtime = {
    lastError: undefined,
    onStartup: event(),
    onInstalled: event(),
    onMessage: event(),
    getURL: (p) => `chrome-extension://testid/${p}`,
    getManifest: () => ({ version }),
    reload: () => { calls.reload++; },
    connectNative(name) {
      calls.connectNative++;
      const port = {
        name,
        sent: [],
        disconnected: false,
        onMessage: event(),
        onDisconnect: event(),
        postMessage(msg) { port.sent.push(structuredClone(msg)); },
        /** Test helper: a message from the native host. */
        receive(msg) { port.onMessage.emit(msg); },
        /** Test helper: the host went away, optionally with Chrome's lastError. */
        disconnect(error) {
          port.disconnected = true;
          runtime.lastError = error ? { message: error } : undefined;
          port.onDisconnect.emit(port);
          runtime.lastError = undefined;
        },
      };
      ports.push(port);
      return port;
    },
  };

  const chrome = {
    tabs: tabsApi,
    tabGroups: tabGroupsApi,
    windows: windowsApi,
    storage: { session: storageArea(session), local: storageArea(local) },
    alarms: { create() {}, onAlarm: event() },
    action: {
      onClicked: event(),
      setBadgeText: ({ text }) => { badge.text = text; },
      setBadgeBackgroundColor: ({ color }) => { badge.color = color; },
      setBadgeTextColor() {},
      setTitle: ({ title }) => { badge.title = title; },
    },
    runtime,
  };

  return { chrome, windows, tabs, groups, session, badge, ports, calls, tabsIn };
}

/** Loads background.js into a fresh context with a mocked chrome. Returns the mock plus helpers. */
export function loadExtension(options) {
  const mock = createChrome(options);
  const timers = new Set();
  const context = vm.createContext({
    chrome: mock.chrome,
    console,
    URL,
    URLSearchParams,
    structuredClone,
    // Timers run fast (≤5 ms) so reconnect backoff doesn't slow the tests.
    setTimeout: (fn, ms) => { const t = setTimeout(fn, Math.min(ms, 5)); timers.add(t); return t; },
    clearTimeout: (t) => { timers.delete(t); clearTimeout(t); },
    setInterval: () => 0,
    clearInterval: () => {},
  });
  const source = readFileSync(new URL("../../extensions/chromium/background.js", import.meta.url), "utf8");
  vm.runInContext(source, context, { filename: "background.js" });
  return {
    ...mock,
    get port() { return mock.ports.at(-1); },
    /** Lets queued async work (the extension's command chain) finish. */
    settle: () => new Promise((r) => setTimeout(r, 30)),
    stop: () => { for (const t of timers) clearTimeout(t); },
  };
}

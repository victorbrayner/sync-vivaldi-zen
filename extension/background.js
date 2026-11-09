'use strict';

/**
 * Extensão do Vivaldi que envia um snapshot das abas abertas para o agente
 * local, que por sua vez grava os arquivos na pasta do Syncthing.
 *
 * Ponto importante: o agente escuta em 127.0.0.1 e a extensão conversa com
 * ele por HTTP local. A porta precisa ser a mesma configurada em
 * agent/config.json.
 */

const CONFIG = {
  endpoint: 'http://127.0.0.1:8765',
  device: 'desktop-windows',
  debounceMs: 1500
};

const PING_ALARM = 'vivaldi-tabs-ping';
const INTERNAL_SCHEME = /^(chrome|vivaldi|about|devtools|chrome-extension|moz-extension):/i;

let snapshotTimer = null;
let sending = false;
let pending = false;

function scheduleSnapshot(delay) {
  if (snapshotTimer) clearTimeout(snapshotTimer);
  snapshotTimer = setTimeout(function () {
    snapshotTimer = null;
    sendSnapshot();
  }, typeof delay === 'number' ? delay : CONFIG.debounceMs);
}

function parseVivExtData(raw) {
  if (!raw) return null;
  if (typeof raw === 'object') return raw;
  try {
    return JSON.parse(raw);
  } catch (error) {
    return null;
  }
}

async function readStackNames() {
  try {
    const data = await chrome.storage.local.get('TAB_STACKING_NAME_MAP');
    const map = data && data.TAB_STACKING_NAME_MAP;
    return map && typeof map === 'object' ? map : {};
  } catch (error) {
    return {};
  }
}

async function readGroupTitles(windows) {
  if (!chrome.tabGroups) return {};
  const ids = new Set();
  windows.forEach(function (win) {
    (win.tabs || []).forEach(function (tab) {
      if (typeof tab.groupId === 'number' && tab.groupId >= 0) ids.add(tab.groupId);
    });
  });

  const titles = {};
  await Promise.all(Array.from(ids).map(async function (id) {
    try {
      const group = await chrome.tabGroups.get(id);
      titles[id] = group && group.title ? group.title : null;
    } catch (error) {
      titles[id] = null;
    }
  }));
  return titles;
}

function stackFor(tab, groupTitles, nameMap) {
  // Vivaldi has used both names for this internal field over time.
  const vivExtData = parseVivExtData(tab.vivExtData || tab.extData);
  if (vivExtData) {
    const group = vivExtData.group;
    if (group && String(group) !== 'undefined') {
      const key = String(group);
      const name =
        vivExtData.fixedGroupTitle ||
        vivExtData.groupTitle ||
        nameMap[key] ||
        nameMap[group] ||
        null;
      return { id: 'v:' + key, name: name || null, source: 'vivaldi' };
    }
  }

  if (typeof tab.groupId === 'number' && tab.groupId >= 0) {
    return {
      id: 'c:' + tab.groupId,
      name: groupTitles[tab.groupId] || null,
      source: 'chromium'
    };
  }

  return null;
}

function exportableUrl(url) {
  if (!url) return false;
  if (INTERNAL_SCHEME.test(url)) return false;
  return /^(https?|file|ftp):/i.test(url);
}

async function buildSnapshot() {
  const allWindows = await chrome.windows.getAll({ populate: true });
  const groupTitles = await readGroupTitles(allWindows);
  const nameMap = await readStackNames();

  // Vivaldi-specific fields (vivExtData) are sometimes only present in the
  // objects returned by tabs.query; merge both sources by tab id.
  let queriedTabs = new Map();
  try {
    const tabs = await chrome.tabs.query({});
    queriedTabs = new Map(tabs.map(function (tab) { return [tab.id, tab]; }));
  } catch (error) {
    queriedTabs = new Map();
  }

  const windows = allWindows
    .filter(function (win) {
      return win.type === 'normal' && !win.incognito;
    })
    .sort(function (a, b) {
      return (a.id || 0) - (b.id || 0);
    });

  let tabCount = 0;
  const exported = windows.map(function (win) {
    const tabs = (win.tabs || [])
      .slice()
      .sort(function (a, b) {
        return a.index - b.index;
      })
      .filter(function (tab) {
        return exportableUrl(tab.url);
      })
      .map(function (tab) {
        tabCount += 1;
        const merged = Object.assign({}, tab, queriedTabs.get(tab.id) || {});
        return {
          title: merged.title || merged.url || '',
          url: merged.url,
          favIconUrl: merged.favIconUrl || '',
          pinned: !!merged.pinned,
          active: !!merged.active,
          stack: stackFor(merged, groupTitles, nameMap)
        };
      });

    return {
      id: win.id,
      focused: !!win.focused,
      tabs: tabs
    };
  });

  // A stack name is usually attached to only one tab; propagate it so every
  // tab of the stack carries the same label.
  const stackNames = {};
  exported.forEach(function (win) {
    win.tabs.forEach(function (tab) {
      if (tab.stack && tab.stack.name && !stackNames[tab.stack.id]) {
        stackNames[tab.stack.id] = tab.stack.name;
      }
    });
  });
  exported.forEach(function (win) {
    win.tabs.forEach(function (tab) {
      if (tab.stack && !tab.stack.name && stackNames[tab.stack.id]) {
        tab.stack.name = stackNames[tab.stack.id];
      }
    });
  });

  return {
    schema: 1,
    device: CONFIG.device,
    browser: 'Vivaldi',
    generatedAt: new Date().toISOString(),
    windowCount: exported.length,
    tabCount: tabCount,
    windows: exported
  };
}

async function post(path, body) {
  const response = await fetch(CONFIG.endpoint + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  if (!response.ok) throw new Error('HTTP ' + response.status);
}

async function setAgentState(ok) {
  try {
    await chrome.action.setBadgeBackgroundColor({ color: ok ? '#1f9d61' : '#c0392b' });
    await chrome.action.setBadgeText({ text: ok ? '' : '!' });
  } catch (error) {
    /* badge é apenas um indicador visual */
  }
}

async function sendSnapshot() {
  if (sending) {
    pending = true;
    return;
  }
  sending = true;
  try {
    const snapshot = await buildSnapshot();
    await post('/snapshot', snapshot);
    await setAgentState(true);
  } catch (error) {
    console.warn('[abas-do-vivaldi] falha ao enviar snapshot:', error);
    await setAgentState(false);
  } finally {
    sending = false;
    if (pending) {
      pending = false;
      scheduleSnapshot(500);
    }
  }
}

function registerEvents() {
  const bump = function () { scheduleSnapshot(); };

  chrome.tabs.onCreated.addListener(bump);
  chrome.tabs.onRemoved.addListener(bump);
  chrome.tabs.onMoved.addListener(bump);
  chrome.tabs.onAttached.addListener(bump);
  chrome.tabs.onDetached.addListener(bump);
  chrome.tabs.onReplaced.addListener(bump);
  chrome.tabs.onActivated.addListener(bump);
  chrome.tabs.onUpdated.addListener(function (tabId, changeInfo) {
    if (
      changeInfo.title ||
      changeInfo.url ||
      changeInfo.favIconUrl ||
      changeInfo.pinned !== undefined ||
      changeInfo.groupId !== undefined ||
      changeInfo.status === 'complete'
    ) {
      bump();
    }
  });

  chrome.windows.onCreated.addListener(bump);
  chrome.windows.onRemoved.addListener(bump);
  chrome.windows.onFocusChanged.addListener(bump);

  if (chrome.tabGroups) {
    chrome.tabGroups.onCreated.addListener(bump);
    chrome.tabGroups.onUpdated.addListener(bump);
    chrome.tabGroups.onRemoved.addListener(bump);
  }

  chrome.alarms.onAlarm.addListener(function (alarm) {
    if (alarm.name === PING_ALARM) sendSnapshot();
  });

  chrome.runtime.onInstalled.addListener(function () {
    scheduleSnapshot(500);
  });

  chrome.runtime.onStartup.addListener(function () {
    scheduleSnapshot(500);
  });

  chrome.action.onClicked.addListener(function () {
    sendSnapshot();
  });
}

/**
 * Em MV3 o service worker pode ser suspenso; garantir o alarme também na
 * inicialização do worker cobre o caso de o navegador já estar aberto.
 */
chrome.alarms.create(PING_ALARM, { periodInMinutes: 1 });
registerEvents();
scheduleSnapshot(500);

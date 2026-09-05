// WinDeck Frontend Application Logic

let appState = {
  pages: [],
  selectedPageId: null,
  status: "disconnected",
  connectedDeviceName: null,
  pendingApproval: null,
  computerName: "WinDeck PC",
  showRunningApps: true,
  showBrowserControl: true,
  controlsLibrary: [],
  installedApps: [],
};

let selectedSlotIndex = 0;
let activeTab = "controls";
let libraryFilter = "";

// -----------------------------------------------------------------------------
// DOM Elements
// -----------------------------------------------------------------------------
const statusDot = document.getElementById("statusDot");
const statusText = document.getElementById("statusText");
const deviceName = document.getElementById("deviceName");
const pairingBanner = document.getElementById("pairingBanner");
const pairingDeviceName = document.getElementById("pairingDeviceName");
const btnApprovePairing = document.getElementById("btnApprovePairing");
const btnDenyPairing = document.getElementById("btnDenyPairing");

const pagesList = document.getElementById("pagesList");
const btnAddPage = document.getElementById("btnAddPage");
const chkRunningApps = document.getElementById("chkRunningApps");
const chkBrowserControl = document.getElementById("chkBrowserControl");
const hostInfo = document.getElementById("hostInfo");

const activePageTitle = document.getElementById("activePageTitle");
const activePageBadge = document.getElementById("activePageBadge");
const btnRenamePage = document.getElementById("btnRenamePage");
const btnDeletePage = document.getElementById("btnDeletePage");
const btnToggleLibrary = document.getElementById("btnToggleLibrary");

const deckGrid = document.getElementById("deckGrid");
const libraryDrawer = document.getElementById("libraryDrawer");
const btnCloseLibrary = document.getElementById("btnCloseLibrary");
const librarySearch = document.getElementById("librarySearch");
const drawerContent = document.getElementById("drawerContent");
const tabButtons = document.querySelectorAll(".tab-btn");

const editModal = document.getElementById("editModal");
const btnCloseModal = document.getElementById("btnCloseModal");
const modalSlotIndex = document.getElementById("modalSlotIndex");
const modalTileLabel = document.getElementById("modalTileLabel");
const modalTileInfo = document.getElementById("modalTileInfo");
const btnModalSave = document.getElementById("btnModalSave");
const btnModalClearSlot = document.getElementById("btnModalClearSlot");

// -----------------------------------------------------------------------------
// Initialization & Polling
// -----------------------------------------------------------------------------
async function init() {
  setupEventListeners();
  await fetchState();
  setInterval(fetchState, 1200); // Live poll updates
}

async function fetchState() {
  try {
    const res = await fetch("/api/state");
    if (!res.ok) return;
    const data = await res.json();
    appState = data;
    render();
  } catch (err) {
    // Backend offline
    statusDot.className = "status-dot disconnected";
    statusText.textContent = "Server Offline";
  }
}

async function postApi(endpoint, body = {}) {
  try {
    const res = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (data.state) {
      appState = data.state;
      render();
    }
  } catch (err) {
    console.error("API error:", err);
  }
}

// -----------------------------------------------------------------------------
// Rendering
// -----------------------------------------------------------------------------
function render() {
  renderConnection();
  renderPages();
  renderGrid();
  renderLibrary();
}

function renderConnection() {
  hostInfo.textContent = `Host: ${appState.computerName || "WinDeck PC"}`;

  if (appState.status === "connected") {
    statusDot.className = "status-dot connected";
    statusText.textContent = "Connected";
    deviceName.textContent = appState.connectedDeviceName || "Mobile Device";
  } else if (appState.status === "awaitingApproval") {
    statusDot.className = "status-dot";
    statusText.textContent = "Pairing Request";
    deviceName.textContent = appState.pendingApproval?.deviceName || "New Device";
  } else if (appState.status === "waiting" || appState.status === "awaitingHello") {
    statusDot.className = "status-dot";
    statusText.textContent = "Waiting for Phone...";
    deviceName.textContent = "Ready to pair via mDNS";
  } else {
    statusDot.className = "status-dot disconnected";
    statusText.textContent = "Disconnected";
    deviceName.textContent = "No phone connected";
  }

  // Pairing banner
  if (appState.pendingApproval) {
    pairingBanner.style.display = "flex";
    pairingDeviceName.textContent = appState.pendingApproval.deviceName || "Device";
  } else {
    pairingBanner.style.display = "none";
  }

  // Toggles
  chkRunningApps.checked = appState.showRunningApps;
  chkBrowserControl.checked = appState.showBrowserControl;
}

function renderPages() {
  pagesList.innerHTML = "";
  appState.pages.forEach((page) => {
    const item = document.createElement("div");
    item.className = `page-item ${page.id === appState.selectedPageId ? "active" : ""}`;
    item.innerHTML = `
      <span>${escapeHtml(page.name)}</span>
      <span class="page-item-badge">P${page.pageNumber}</span>
    `;
    item.addEventListener("click", () => {
      postApi("/api/select_page", { pageId: page.id });
    });
    pagesList.appendChild(item);
  });

  const activePage = appState.pages.find((p) => p.id === appState.selectedPageId) || appState.pages[0];
  if (activePage) {
    activePageTitle.textContent = activePage.name;
    activePageBadge.textContent = `Page ${activePage.pageNumber} • 10 Slots`;
  }
}

function renderGrid() {
  deckGrid.innerHTML = "";
  const activePage = appState.pages.find((p) => p.id === appState.selectedPageId) || appState.pages[0];
  const tiles = activePage ? activePage.tiles : [];

  for (let i = 0; i < 10; i++) {
    const tile = tiles[i];
    const keycap = document.createElement("div");
    keycap.className = `keycap ${tile ? "" : "empty"} ${selectedSlotIndex === i ? "selected" : ""}`;
    keycap.dataset.slot = i;

    // Drag & Drop
    keycap.draggable = true;
    keycap.addEventListener("dragstart", (e) => {
      e.dataTransfer.setData("text/plain", JSON.stringify({ type: "slot", slotIndex: i }));
    });
    keycap.addEventListener("dragover", (e) => e.preventDefault());
    keycap.addEventListener("drop", (e) => {
      e.preventDefault();
      const raw = e.dataTransfer.getData("text/plain");
      if (!raw) return;
      try {
        const payload = JSON.parse(raw);
        if (payload.type === "slot") {
          postApi("/api/swap_tiles", { pageId: activePage.id, slotA: payload.slotIndex, slotB: i });
        } else if (payload.type === "library") {
          postApi("/api/set_tile", { pageId: activePage.id, slotIndex: i, tileType: payload.tileType });
        }
      } catch (err) {}
    });

    if (tile) {
      const iconSrc = tile.iconData ? `data:image/png;base64,${tile.iconData}` : "";
      const label = tile.customLabel || tile.tileType?.name || tile.tileType?.action || "Action";
      keycap.innerHTML = `
        <span class="keycap-slot-num">${i + 1}</span>
        ${iconSrc ? `<img class="keycap-icon" src="${iconSrc}" alt="icon">` : ""}
        <span class="keycap-label">${escapeHtml(label)}</span>
      `;
    } else {
      keycap.innerHTML = `
        <span class="keycap-slot-num">${i + 1}</span>
        <span class="keycap-label" style="color: var(--text-tertiary);">Empty</span>
      `;
    }

    keycap.addEventListener("click", () => {
      selectedSlotIndex = i;
      renderGrid();
    });

    keycap.addEventListener("dblclick", () => {
      openModal(i, tile);
    });

    deckGrid.appendChild(keycap);
  }
}

function renderLibrary() {
  drawerContent.innerHTML = "";
  let items = [];

  if (activeTab === "controls") {
    items = appState.controlsLibrary || [];
  } else if (activeTab === "apps") {
    items = appState.installedApps || [];
  } else if (activeTab === "browser") {
    items = [
      { name: "Tab 1", action: "switchTab1", type: "browserControl" },
      { name: "Tab 2", action: "switchTab2", type: "browserControl" },
      { name: "Tab 3", action: "switchTab3", type: "browserControl" },
      { name: "Tab 4", action: "switchTab4", type: "browserControl" },
      { name: "Tab 5", action: "switchTab5", type: "browserControl" },
      { name: "Back", action: "back", type: "browserControl" },
      { name: "Forward", action: "forward", type: "browserControl" },
      { name: "Refresh", action: "refresh", type: "browserControl" },
      { name: "New Tab", action: "newTab", type: "browserControl" },
      { name: "Close Tab", action: "closeTab", type: "browserControl" },
    ];
  } else if (activeTab === "websites") {
    items = [
      { name: "Google", url: "https://google.com", type: "website" },
      { name: "YouTube", url: "https://youtube.com", type: "website" },
      { name: "GitHub", url: "https://github.com", type: "website" },
      { name: "Twitter / X", url: "https://x.com", type: "website" },
      { name: "Reddit", url: "https://reddit.com", type: "website" },
    ];
  } else if (activeTab === "macros") {
    items = [
      { name: "Win + D (Desktop)", macro: "WIN+D", type: "shortcut" },
      { name: "Alt + Tab", macro: "ALT+TAB", type: "shortcut" },
      { name: "Ctrl + Shift + Esc (Task Mgr)", macro: "CTRL+SHIFT+ESC", type: "shortcut" },
      { name: "Win + L (Lock)", macro: "WIN+L", type: "shortcut" },
    ];
  }

  // Filter
  const q = libraryFilter.toLowerCase().trim();
  const filtered = items.filter((it) => (it.name || it.action || "").toLowerCase().includes(q));

  filtered.forEach((it) => {
    const el = document.createElement("div");
    el.className = "library-item";
    el.draggable = true;

    const tileType = {
      type: it.type || (activeTab === "controls" ? "systemControl" : "app"),
      name: it.name,
      action: it.action,
      url: it.url,
      bundleIdentifier: it.path || it.bundleIdentifier,
    };

    el.addEventListener("dragstart", (e) => {
      e.dataTransfer.setData("text/plain", JSON.stringify({ type: "library", tileType }));
    });

    const iconSrc = it.iconData ? `data:image/png;base64,${it.iconData}` : "";
    el.innerHTML = `
      ${iconSrc ? `<img class="library-item-icon" src="${iconSrc}">` : `<div style="font-size: 20px;">⚡</div>`}
      <span class="library-item-label">${escapeHtml(it.name || it.action || "Action")}</span>
    `;

    el.addEventListener("click", () => {
      const activePage = appState.pages.find((p) => p.id === appState.selectedPageId) || appState.pages[0];
      if (activePage) {
        postApi("/api/set_tile", {
          pageId: activePage.id,
          slotIndex: selectedSlotIndex,
          tileType,
        });
      }
    });

    drawerContent.appendChild(el);
  });
}

// -----------------------------------------------------------------------------
// Modal
// -----------------------------------------------------------------------------
function openModal(slotIndex, tile) {
  modalSlotIndex.textContent = slotIndex + 1;
  modalTileLabel.value = tile?.customLabel || "";
  modalTileInfo.textContent = tile
    ? `${tile.tileType.type}: ${tile.tileType.action || tile.tileType.name || tile.tileType.url || ""}`
    : "Empty slot";
  editModal.style.display = "flex";
}

function closeModal() {
  editModal.style.display = "none";
}

// -----------------------------------------------------------------------------
// Event Listeners
// -----------------------------------------------------------------------------
function setupEventListeners() {
  btnAddPage.addEventListener("click", () => {
    const name = prompt("Enter page name:", `Page ${appState.pages.length + 1}`);
    if (name) postApi("/api/add_page", { name });
  });

  btnRenamePage.addEventListener("click", () => {
    const activePage = appState.pages.find((p) => p.id === appState.selectedPageId);
    if (!activePage) return;
    const name = prompt("Rename page:", activePage.name);
    if (name) postApi("/api/rename_page", { pageId: activePage.id, name });
  });

  btnDeletePage.addEventListener("click", () => {
    const activePage = appState.pages.find((p) => p.id === appState.selectedPageId);
    if (!activePage || appState.pages.length <= 1) {
      alert("Cannot delete the only remaining page.");
      return;
    }
    if (confirm(`Delete page "${activePage.name}"?`)) {
      postApi("/api/delete_page", { pageId: activePage.id });
    }
  });

  btnToggleLibrary.addEventListener("click", () => {
    libraryDrawer.style.display = libraryDrawer.style.display === "none" ? "flex" : "none";
  });

  btnCloseLibrary.addEventListener("click", () => {
    libraryDrawer.style.display = "none";
  });

  chkRunningApps.addEventListener("change", (e) => {
    postApi("/api/set_toggles", { showRunningApps: e.target.checked });
  });

  chkBrowserControl.addEventListener("change", (e) => {
    postApi("/api/set_toggles", { showBrowserControl: e.target.checked });
  });

  btnApprovePairing.addEventListener("click", () => {
    if (appState.pendingApproval) {
      postApi("/api/approve_pairing", { clientId: appState.pendingApproval.clientID });
    }
  });

  btnDenyPairing.addEventListener("click", () => {
    if (appState.pendingApproval) {
      postApi("/api/deny_pairing", { clientId: appState.pendingApproval.clientID });
    }
  });

  tabButtons.forEach((btn) => {
    btn.addEventListener("click", () => {
      tabButtons.forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      activeTab = btn.dataset.tab;
      renderLibrary();
    });
  });

  librarySearch.addEventListener("input", (e) => {
    libraryFilter = e.target.value;
    renderLibrary();
  });

  btnCloseModal.addEventListener("click", closeModal);

  btnModalSave.addEventListener("click", () => {
    const activePage = appState.pages.find((p) => p.id === appState.selectedPageId);
    if (!activePage) return;
    const tile = activePage.tiles[selectedSlotIndex];
    if (tile) {
      tile.customLabel = modalTileLabel.value.trim() || null;
      postApi("/api/set_tile", {
        pageId: activePage.id,
        slotIndex: selectedSlotIndex,
        tileType: tile.tileType,
        customLabel: tile.customLabel,
      });
    }
    closeModal();
  });

  btnModalClearSlot.addEventListener("click", () => {
    const activePage = appState.pages.find((p) => p.id === appState.selectedPageId);
    if (activePage) {
      postApi("/api/clear_tile", { pageId: activePage.id, slotIndex: selectedSlotIndex });
    }
    closeModal();
  });
}

function escapeHtml(str) {
  if (!str) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

document.addEventListener("DOMContentLoaded", init);

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
  document.querySelectorAll("[data-ui-icon]").forEach(el => { el.innerHTML = uiIcon(el.dataset.uiIcon); });
  setupEventListeners();
  await fetchState();
  setInterval(fetchState, 1200); // Live poll updates
}

async function fetchState() {
  if (tileDrag || editModal.style.display === "flex") return;
  try {
    const res = await fetch("/api/state");
    if (!res.ok) return;
    const data = await res.json();
    if (tileDrag || editModal.style.display === "flex") return;
    if (JSON.stringify(appState) !== JSON.stringify(data)) {
      appState = data;
      render();
    }
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
    if (data.error) { alert(data.error); return false; }
    if (data.state) {
      appState = data.state;
      render();
    }
    return true;
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
  hostInfo.textContent = `${appState.computerName || "WinDeck PC"} · Windows Beta`;
  document.getElementById("appVersion").textContent = appState.appVersion ? `v${appState.appVersion.split("-")[0]}` : "";

  document.getElementById("disconnectDevice").style.display = appState.status === "connected" ? "" : "none";
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

  document.getElementById("phoneScreenStatus").textContent = statusText.textContent;
  document.querySelector(".phone-status-pill .pill-dot").style.backgroundColor = appState.status === "connected" ? "var(--accent-green)" : "var(--accent-orange)";
  document.getElementById("headerConnectionStatus").textContent = appState.status === "connected" ? "Phone connected" : "Searching for Phone…";
  document.getElementById("connectionPill").classList.toggle("connected", appState.status === "connected");
  document.getElementById("btnSync").disabled = appState.status !== "connected";
  document.getElementById("keyboardStatus").textContent = appState.keyboardBacklight?.message || "Checking keyboard-light support…";
  document.getElementById("keyboardSupportedNote").hidden = !appState.keyboardBacklight?.supported;
  document.getElementById("bonjourStatus").textContent = appState.status === "connected" ? "Connected to your phone" : "Ready for connections";

  // Pairing banner
  if (appState.pendingApproval) {
    pairingBanner.style.display = "flex";
    pairingDeviceName.textContent = appState.pendingApproval.deviceName || "Device";
  } else {
    pairingBanner.style.display = "none";
  }

  // Toggles
  document.getElementById("chkOBS").checked = appState.showOBS;
  document.getElementById("chkDiscord").checked = appState.showDiscord;
  document.getElementById("obsStatus").textContent = appState.obsStatus;
  const phones = document.getElementById("trustedPhones");
  phones.replaceChildren();
  (appState.trustedDevices || []).forEach(phone => {
    const row = document.createElement("p");
    const forget = document.createElement("button");
    forget.type = "button";
    forget.className = "btn btn-secondary";
    forget.textContent = "Forget";
    forget.onclick = () => postApi("/api/forget_device", {clientId: phone.clientID});
    row.append(phone.deviceName + " ", forget);
    phones.append(row);
  });
  if (!phones.childElementCount) phones.textContent = "No paired phones";
  document.getElementById("chkLogin").checked = appState.launchAtLogin;
  chkRunningApps.checked = appState.showRunningApps;
  chkBrowserControl.checked = appState.showBrowserControl;
}

function renderPages() {
  pagesList.replaceChildren();
  const dynamic = document.getElementById("dynamicPagesList");
  dynamic.replaceChildren();
  const saved = appState.pages.filter(page => !page.readOnly);
  appState.pages.forEach(page => {
    const count = page.tiles.filter(Boolean).length;
    const item = document.createElement("button");
    item.className = `page-item ${page.id === appState.selectedPageId ? "active" : ""}`;
    item.setAttribute("aria-current", page.id === appState.selectedPageId ? "page" : "false");
    const icon = page.readOnly ? uiIcon(page.name.includes("Discord") ? "chat" : page.name.includes("OBS") ? "record" : "apps") :
      `<span class="page-grid-icon" aria-hidden="true">${Array.from({length:20}, (_,i) => `<i class="${page.tiles[i] ? "filled" : ""}"></i>`).join("")}</span>`;
    item.innerHTML = `${icon}<span class="page-item-copy"><span class="page-name">${escapeHtml(page.name)}</span><span class="page-item-badge">${page.readOnly ? "Live page" : `${count} of 20 slots`}</span></span>`;
    item.onclick = () => postApi("/api/select_page", {pageId:page.id});
    (page.readOnly ? dynamic : pagesList).append(item);
  });
  document.getElementById("dynamicPagesLabel").hidden = !dynamic.childElementCount;
  const page = appState.pages.find(p => p.id === appState.selectedPageId) || appState.pages[0];
  if (!page) return;
  activePageTitle.textContent = page.name;
  activePageBadge.textContent = page.readOnly ? "Live controls from your computer" : `${page.tiles.filter(Boolean).length} of 20 slots configured · Drag controls below onto slots`;
  document.getElementById("btnTriggers").disabled = page.readOnly;
  btnDeletePage.disabled = btnRenamePage.disabled = btnToggleLibrary.disabled = page.readOnly;
  libraryDrawer.hidden = page.readOnly;
  document.getElementById("phonePagination").innerHTML = saved.map(p => `<i class="${p.id === page.id ? "active" : ""}"></i>`).join("");
}

function renderGrid() {
  deckGrid.innerHTML = "";
  const activePage = appState.pages.find((p) => p.id === appState.selectedPageId) || appState.pages[0];
  const tiles = activePage ? activePage.tiles : [];
  if (!activePage) return;

  const rows = appState.gridRows || 2;
  deckGrid.style.gridTemplateRows = "";
  deckGrid.dataset.rows = rows;
  selectedSlotIndex = Math.min(selectedSlotIndex, rows * 5 - 1);
  for (let i = 0; i < rows * 5; i++) {
    const tile = tiles[i];
    const keycap = document.createElement("div");
    keycap.setAttribute("role", "button");
    keycap.tabIndex = 0;
    keycap.className = `keycap ${tile ? "" : "empty"} ${selectedSlotIndex === i ? "selected" : ""}`;
    keycap.dataset.slot = i;
    keycap.setAttribute("aria-label", `Slot ${i + 1}, ${tile?.customLabel || tile?.tileType?.name || tile?.tileType?.action || "Empty"}`);

    if (!activePage.readOnly) {
      keycap.dataset.dropSlot = i;
      if (tile) enableTileDrag(keycap, {type:"slot", pageId:activePage.id, slotIndex:i});
    }

    if (tile) {
      const label = tileLabel(tile);
      keycap.innerHTML = `
        <span class="keycap-slot-num">${i + 1}</span>
        <span class="keycap-label">${escapeHtml(label)}</span>
      `;
      keycap.insertBefore(artwork(tile.iconData, "keycap-icon", tile.tileType?.type), keycap.querySelector(".keycap-label"));
      keycap.title = label;
      if (!activePage.readOnly) {
        const actions = document.createElement("span");
        actions.className = "tile-actions";
        for (const [kind, title, icon] of [["edit", "Edit tile", uiIcon("edit")], ["remove", "Remove tile", "−"]]) {
          const button = document.createElement("button");
          button.className = `tile-action tile-${kind}`;
          button.setAttribute("aria-label", `${title} ${i + 1}`);
          button.title = title;
          button.innerHTML = icon;
          button.onpointerdown = event => event.stopPropagation();
          button.onclick = event => {
            event.stopPropagation(); selectedSlotIndex = i;
            if (kind === "edit") openModal(i, tile);
            else postApi("/api/clear_tile", {pageId:activePage.id, slotIndex:i});
          };
          actions.append(button);
        }
        keycap.append(actions);
      }
    } else {
      keycap.innerHTML = `
        <span class="keycap-slot-num">${i + 1}</span>
        <span class="keycap-label" style="color: var(--text-tertiary);">Empty</span>
      `;
    }

    keycap.addEventListener("click", () => {
      if (performance.now() < suppressTileClickUntil) return;
      if (activePage.readOnly) {
        if (tile) postApi("/api/trigger_live_slot", {pageId: activePage.id, slotIndex: i});
        return;
      }
      selectedSlotIndex = i;
      renderGrid();
    });

    keycap.addEventListener("keydown", (e) => {
      if (e.target === keycap && e.key === "Enter" && !activePage.readOnly) { e.preventDefault(); selectedSlotIndex = i; openModal(i, tile); }
    });
    keycap.addEventListener("dblclick", () => {
      if (!activePage.readOnly) openModal(i, tile);
    });

    deckGrid.appendChild(keycap);
  }
}

function renderLibrary() {
  const setup = activeTab === "setup";
  document.getElementById("setupPanel").hidden = !setup;
  drawerContent.hidden = setup;
  document.getElementById("drawerTip").hidden = setup;
  document.getElementById("addCustomTile").hidden = activeTab !== "websites";
  document.getElementById("librarySearchBar").hidden = !["apps", "shortcuts", "websites"].includes(activeTab);
  if (setup) return;
  drawerContent.setAttribute("aria-labelledby", `tab-${activeTab}`);
  drawerContent.replaceChildren();
  const shortcuts = [
    {name:"Desktop", macro:"WIN+D"}, {name:"Switch App", macro:"ALT+TAB"},
    {name:"Task Manager", macro:"CTRL+SHIFT+ESC"}, {name:"Copy", macro:"CTRL+C"},
    {name:"Paste", macro:"CTRL+V"}, {name:"Undo", macro:"CTRL+Z"},
    {name:"Save", macro:"CTRL+S"}, {name:"Find", macro:"CTRL+F"}
  ].map(item => ({...item, type:"shortcut"}));
  const items = activeTab === "controls" ? appState.controlsLibrary : activeTab === "apps" ? appState.installedApps :
    activeTab === "websites" ? appState.websitesLibrary : shortcuts;
  const q = activeTab === "controls" ? "" : libraryFilter.toLowerCase().trim();
  const filtered = (items || []).filter(item => (item.name || item.action || "").toLowerCase().includes(q));
  filtered.forEach(it => {
    const el = document.createElement("button");
    el.className = "library-item";
    const tileType = {type:it.type, name:it.macro || it.name, action:it.action, url:it.url, bundleIdentifier:it.path || it.bundleIdentifier};
    enableTileDrag(el, {type:"library", tileType, customLabel:it.macro ? it.name : null});
    el.append(artwork(it.iconData, "library-item-icon", it.type));
    const label = document.createElement("span");
    label.className = "library-item-label";
    label.textContent = it.name || it.action;
    el.append(label);
    el.title = it.macro ? `${it.name} · ${it.macro}` : it.name;
    el.onclick = async () => {
      if (performance.now() < suppressTileClickUntil) return;
      if (await postApi("/api/set_tile", {pageId:appState.selectedPageId, slotIndex:selectedSlotIndex, tileType, customLabel:it.macro ? it.name : null})) {
        showToast(`${it.name} assigned to slot ${selectedSlotIndex + 1}`);
      }
    };
    drawerContent.append(el);
  });
  if (!filtered.length) {
    const empty = document.createElement("p");
    empty.className = "empty-library";
    empty.textContent = q ? "No matching items. Try a different search." : "No items available yet.";
    drawerContent.append(empty);
  }
  if (activeTab === "controls" && !appState.keyboardBacklight?.supported) {
    const notice = document.createElement("p");
    notice.className = "library-notice";
    notice.textContent = appState.keyboardBacklight?.message || "Checking keyboard-light support…";
    drawerContent.append(notice);
  }
}

function tileLabel(tile) {
  return tile.customLabel || appState.controlsLibrary?.find(it => it.action === tile.tileType?.action)?.name || tile.tileType?.name || tile.tileType?.action || "Action";
}

function artwork(data, className, type) {
  const fallback = () => {
    const span = document.createElement("span");
    span.className = className;
    span.innerHTML = uiIcon(type === "website" ? "globe" : type === "shortcut" ? "bolt" : "apps");
    return span;
  };
  if (!data) return fallback();
  const img = document.createElement("img");
  img.className = className;
  img.src = `data:image/png;base64,${data}`;
  img.alt = "";
  img.draggable = false;
  img.onerror = () => img.replaceWith(fallback());
  return img;
}

let toastTimer;
function showToast(message) {
  const toast = document.getElementById("toast");
  toast.textContent = message;
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.hidden = true; }, 3000);
}

// Pointer dragging works in WebView2 and with touch, without native image dragging.
let tileDrag = null;
let suppressTileClickUntil = 0;
function enableTileDrag(element, payload) {
  element.draggable = false;
  element.addEventListener("dragstart", event => event.preventDefault());
  element.addEventListener("pointerdown", event => {
    if (event.button !== 0 || event.target.closest(".tile-action")) return;
    tileDrag = {payload, element, id:event.pointerId, x:event.clientX, y:event.clientY, active:false};
    element.setPointerCapture(event.pointerId);
  });
}
document.addEventListener("pointermove", event => {
  if (!tileDrag || event.pointerId !== tileDrag.id) return;
  const drag = tileDrag;
  if (!drag.active && Math.hypot(event.clientX-drag.x, event.clientY-drag.y) < 7) return;
  event.preventDefault();
  if (!drag.active) {
    drag.active = true;
    drag.ghost = drag.element.cloneNode(true);
    drag.ghost.className = "tile-drag-preview";
    drag.ghost.removeAttribute("id"); drag.ghost.querySelectorAll(".tile-actions").forEach(el=>el.remove());
    document.body.append(drag.ghost);
    document.body.classList.add("dragging-tile");
  }
  drag.ghost.style.left = `${event.clientX+14}px`; drag.ghost.style.top = `${event.clientY+14}px`;
  document.querySelectorAll(".drop-target").forEach(el=>el.classList.remove("drop-target"));
  const target = document.elementFromPoint(event.clientX,event.clientY)?.closest("[data-drop-slot]");
  target?.classList.add("drop-target");
}, {passive:false});
function finishTileDrag(event, cancelled=false) {
  if (!tileDrag || event.pointerId !== tileDrag.id) return;
  const drag = tileDrag;
  tileDrag = null;
  drag.ghost?.remove(); document.body.classList.remove("dragging-tile");
  document.querySelectorAll(".drop-target").forEach(el=>el.classList.remove("drop-target"));
  if (!drag.active) return;
  suppressTileClickUntil = performance.now()+400;
  const target = !cancelled && document.elementFromPoint(event.clientX,event.clientY)?.closest("[data-drop-slot]");
  if (!target) return;
  const slotIndex = Number(target.dataset.dropSlot);
  selectedSlotIndex = slotIndex;
  if (drag.payload.type === "slot") {
    postApi("/api/swap_tiles", {pageId:drag.payload.pageId, slotA:drag.payload.slotIndex, slotB:slotIndex});
  } else {
    postApi("/api/set_tile", {pageId:appState.selectedPageId, slotIndex, tileType:drag.payload.tileType, customLabel:drag.payload.customLabel});
  }
}
document.addEventListener("pointerup", event=>finishTileDrag(event));
document.addEventListener("pointercancel", event=>finishTileDrag(event,true));

// -----------------------------------------------------------------------------
// Modal
// -----------------------------------------------------------------------------
let editingTile = null;
let editedIcon = undefined;
function openModal(slotIndex, tile) {
  selectedSlotIndex = slotIndex;
  editingTile = {pageId:appState.selectedPageId, slotIndex};
  editedIcon = undefined;
  document.getElementById("tileIconFile").value = "";
  document.getElementById("tileIconPreview").replaceChildren(artwork(tile?.iconData, "edit-icon-preview", tile?.tileType?.type));
  modalSlotIndex.textContent = slotIndex + 1;
  modalTileLabel.value = tile?.customLabel || "";
  modalTileInfo.textContent = tile
    ? `${tile.tileType.type}: ${tile.tileType.action || tile.tileType.name || tile.tileType.url || ""}`
    : "Empty slot";
  editModal.style.display = "flex";
}

function closeModal() {
  editModal.style.display = "none";
  editingTile = null;
}

// -----------------------------------------------------------------------------
// Event Listeners
// -----------------------------------------------------------------------------
function setupEventListeners() {
  document.getElementById("disconnectDevice").onclick = () => postApi("/api/disconnect_device", {clientId: appState.connectedClientID});
  document.getElementById("chkLogin").onchange = e => postApi("/api/launch_at_login", {enabled: e.target.checked});
  document.getElementById("btnTriggers").onclick = () => {
    const page = appState.pages.find(p => p.id === appState.selectedPageId);
    if (!page || page.readOnly) return;
    const apps = prompt("Switch to this page when an app comes to the foreground. Enter executable names separated by commas.", page.triggerApps.join(", "));
    if (apps !== null) postApi("/api/page_triggers", {pageId: page.id, apps});
  };
  document.getElementById("btnSync").onclick = async () => {
    if (await postApi("/api/sync")) showToast("Deck sent to phone");
  };
  const websiteDialog = document.getElementById("websiteDialog");
  document.getElementById("addCustomTile").onclick = () => websiteDialog.showModal();
  document.getElementById("cancelWebsite").onclick = () => websiteDialog.close();
  document.getElementById("websiteForm").onsubmit = async event => {
    event.preventDefault();
    const name = document.getElementById("websiteName").value.trim();
    const url = document.getElementById("websiteUrl").value.trim();
    if (await postApi("/api/set_tile", {pageId:appState.selectedPageId, slotIndex:selectedSlotIndex, tileType:{type:"website", name, url}})) {
      websiteDialog.close();
      showToast(`${name} assigned to slot ${selectedSlotIndex + 1}`);
    }
  };
  const shortcutInput = document.getElementById("shortcutInput");
  const assign = document.getElementById("assignShortcut");
  const modifiers = document.querySelectorAll("[data-modifier]");
  const updateShortcut = () => { assign.disabled = !shortcutInput.value.trim(); };
  modifiers.forEach(button => { button.onclick = () => {
    button.setAttribute("aria-pressed", button.getAttribute("aria-pressed") !== "true");
    const keys = Array.from(modifiers).filter(b => b.getAttribute("aria-pressed") === "true").map(b => b.dataset.modifier);
    const key = shortcutInput.value.split("+").filter(part => !["WIN","ALT","CTRL","SHIFT"].includes(part)).pop();
    shortcutInput.value = [...keys, ...(key ? [key] : [])].join("+");
    updateShortcut();
  }; });
  shortcutInput.onkeydown = event => {
    if (event.key === "Tab") return;
    if (["Backspace", "Delete"].includes(event.key) && !event.ctrlKey && !event.altKey) {
      shortcutInput.value = ""; modifiers.forEach(b => b.setAttribute("aria-pressed", "false")); updateShortcut(); event.preventDefault(); return;
    }
    if (["Control", "Shift", "Alt", "Meta"].includes(event.key)) return;
    event.preventDefault();
    const keys = [];
    for (const [pressed, name] of [[event.metaKey,"WIN"],[event.altKey,"ALT"],[event.ctrlKey,"CTRL"],[event.shiftKey,"SHIFT"]]) {
      if (pressed || document.querySelector(`[data-modifier="${name}"]`).getAttribute("aria-pressed") === "true") keys.push(name);
    }
    const key = ({" ":"SPACE", Escape:"ESC", ArrowLeft:"LEFT", ArrowRight:"RIGHT", ArrowUp:"UP", ArrowDown:"DOWN"})[event.key] || event.key.toUpperCase();
    shortcutInput.value = [...keys, key].join("+");
    modifiers.forEach(button => button.setAttribute("aria-pressed", keys.includes(button.dataset.modifier)));
    updateShortcut();
  };
  shortcutInput.oninput = updateShortcut;
  document.getElementById("shortcutForm").onsubmit = async event => {
    event.preventDefault();
    const name = shortcutInput.value.trim();
    if (name && await postApi("/api/set_tile", {pageId:appState.selectedPageId, slotIndex:selectedSlotIndex, tileType:{type:"shortcut", name}})) showToast(`${name} assigned to slot ${selectedSlotIndex + 1}`);
  };
  document.getElementById("checkUpdates").onclick = () => postApi("/api/check_updates", {});
  document.getElementById("supportMacDeck").onclick = () => postApi("/api/support", {});
  const settings = document.getElementById("integrationSettings");
  const port = document.getElementById("obsPort");
  const password = document.getElementById("obsPassword");
  const clear = document.getElementById("clearPassword");
  document.getElementById("openIntegrations").onclick = () => {
    port.value = appState.obsPort;
    password.value = "";
    clear.checked = false;
    settings.showModal();
  };
  document.getElementById("closeIntegrations").onclick = () => settings.close();
  document.getElementById("integrationForm").onsubmit = async (event) => {
    event.preventDefault();
    if (await postApi("/api/obs_settings", {port: Number(port.value), password: clear.checked ? "" : password.value, clearPassword: clear.checked})) {
      password.value = "";
      settings.close();
    }
  };
  for (const name of ["OBS", "Discord"]) {
    document.getElementById("chk" + name).onchange = event =>
      postApi("/api/set_toggles", {["show" + name]: event.target.checked});
  }
  btnAddPage.addEventListener("click", () => {
    const name = prompt("Enter page name:", `Page ${appState.pages.filter(p => !p.readOnly).length + 1}`);
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
    if (!activePage || appState.pages.filter(p => !p.readOnly).length <= 1) {
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
      tabButtons.forEach((b) => { b.classList.remove("active"); b.setAttribute("aria-selected", "false"); });
      btn.classList.add("active");
      btn.setAttribute("aria-selected", "true");
      activeTab = btn.dataset.tab;
      renderLibrary();
    });
  });

  tabButtons.forEach((button, index) => button.addEventListener("keydown", event => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const target = event.key === "Home" ? 0 : event.key === "End" ? tabButtons.length - 1 :
      (index + (event.key === "ArrowRight" ? 1 : -1) + tabButtons.length) % tabButtons.length;
    tabButtons[target].focus(); tabButtons[target].click();
  }));
  librarySearch.addEventListener("input", (e) => {
    libraryFilter = e.target.value;
    renderLibrary();
  });

  btnCloseModal.addEventListener("click", closeModal);

  document.getElementById("tileIconFile").onchange = async event => {
    const file = event.target.files[0];
    if (!file) return;
    if (file.size > 5 * 1024 * 1024) { showToast("Choose an image smaller than 5 MB."); return; }
    try {
      const data = await new Promise((resolve, reject) => {
        const reader = new FileReader(); reader.onload = () => resolve(reader.result.split(",")[1]); reader.onerror = reject; reader.readAsDataURL(file);
      });
      editedIcon = data;
      const img = document.createElement("img"); img.className = "edit-icon-preview";
      img.src = `data:${file.type};base64,${data}`; img.alt = "Selected tile icon";
      document.getElementById("tileIconPreview").replaceChildren(img);
    } catch { showToast("This image could not be opened."); }
  };
  document.getElementById("resetTileIcon").onclick = () => {
    editedIcon = null;
    document.getElementById("tileIconPreview").textContent = "Default icon will be restored";
  };
  btnModalSave.addEventListener("click", async () => {
    if (!editingTile) return;
    const body = {...editingTile, customLabel:modalTileLabel.value.trim() || null};
    if (editedIcon !== undefined) body.customIcon = editedIcon;
    if (await postApi("/api/edit_tile", body)) closeModal();
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

function uiIcon(name) {
  const paths = {
    grid:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    apps:'<rect x="3" y="4" width="15" height="13" rx="2"/><path d="M7 17v3h14V8h-3"/>',
    phone:'<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 5h4M11 19h2"/>',
    sync:'<path d="M20 8a8 8 0 0 0-14-3L3 8m0-5v5h5m-4 8a8 8 0 0 0 14 3l3-3m0 5v-5h-5"/>',
    globe:'<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18M5 7h14M5 17h14"/>',
    controls:'<path d="m5 15 7-7 7 7"/>',
    bolt:'<path d="m13 2-9 12h7l-1 8 10-13h-8z"/>',
    edit:'<path d="m15 4 5 5M4 15 16 3a2 2 0 0 1 3 0l2 2a2 2 0 0 1 0 3L9 20l-6 1z"/>',
    power:'<path d="M12 2v10M6 5a9 9 0 1 0 12 0"/>',
    record:'<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4" fill="currentColor" stroke="none"/>',
    chat:'<path d="M4 3h11a2 2 0 0 1 2 2v9H8l-5 4V5a2 2 0 0 1 1-2Z"/><path d="M17 7h3a2 2 0 0 1 2 2v12l-5-4h-6v-3"/>',
    settings:'<path d="m9 3 1-2h4l1 2 3 2 3 1v4l-2 2v3l1 3-3 3-3-1h-3l-2 2H5l-1-3-2-3-2-1v-4l2-2V6l3-3 3 1z" transform="translate(2 2) scale(.82)"/><circle cx="12" cy="12" r="3"/>',
    heart:'<path d="M20 5a5 5 0 0 0-8 1 5 5 0 0 0-8-1c-5 5 3 12 8 16 5-4 13-11 8-16Z"/>',
    keyboard:'<rect x="2" y="7" width="20" height="13" rx="2"/><path d="M5 11h1m3 0h1m3 0h1m3 0h1M5 15h1m3 0h1m3 0h1m3 0h1M8 18h8M12 1v3M5 2l2 3m12-3-2 3"/>',
    broadcast:'<circle cx="12" cy="10" r="2" fill="currentColor"/><path d="M12 12v10M7 5a7 7 0 0 0 0 10m10-10a7 7 0 0 1 0 10M4 2a11 11 0 0 0 0 16M20 2a11 11 0 0 1 0 16"/>'
  };
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.grid}</svg>`;
}

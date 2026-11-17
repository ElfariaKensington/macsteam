// Steam properties sidebar item + in-window achievements list.
// Everything is an overlay on documentElement; Steam's React tree is untouched.
(() => {
  if (window.__macsteamPropertiesInstalled) return;
  window.__macsteamPropertiesInstalled = true;

  const pending = new Map();
  let sequence = 0;
  let toastTimer = 0;
  let button = null;
  let nativeSelected = null;

  // Remove panes and highlight overrides left behind by a previous injection.
  document.querySelectorAll("#macsteam-properties-pane, #macsteam-properties-picker")
    .forEach((el) => el.remove());
  document.querySelectorAll("[data-macsteam-dimmed]")
    .forEach((el) => el.removeAttribute("data-macsteam-dimmed"));
  // Older builds dimmed the selected tab with inline styles. Clear only that
  // exact pattern inside the properties sidebar so the native highlight returns.
  document.querySelectorAll('[style*="background-color"]').forEach((el) => {
    if (el.style.backgroundColor !== "transparent" ||
        el.style.color !== "rgb(184, 188, 191)") return;
    const rect = el.getBoundingClientRect();
    if (rect.left > 300 || rect.width < 120 || rect.height < 24) return;
    el.style.removeProperty("background-color");
    el.style.removeProperty("color");
    if (!el.getAttribute("style")) el.removeAttribute("style");
  });

  const layer = document.createElement("div");
  layer.id = "macsteam-properties-layer";
  layer.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483644;";
  document.documentElement.appendChild(layer);

  const style = document.createElement("style");
  style.textContent = "[data-macsteam-dimmed]{background-color:transparent!important;" +
    "color:rgb(184,188,191)!important;}" +
    "#macsteam-properties-pane ::-webkit-scrollbar{width:10px;}" +
    "#macsteam-properties-pane ::-webkit-scrollbar-track{background:#1b1f26;}" +
    "#macsteam-properties-pane ::-webkit-scrollbar-thumb{background:#3d4450;border-radius:5px;}";
  layer.appendChild(style);

  window.macsteamAchievementResult = (request, ok, message, data) => {
    const done = pending.get(String(request));
    if (!done) return;
    pending.delete(String(request));
    done([!!ok, String(message || ""), data || null]);
  };

  function send(payload, timeout = 15000) {
    return new Promise((resolve) => {
      const request = String(++sequence);
      pending.set(request, resolve);
      try {
        window.macsteamAchievements(JSON.stringify(Object.assign({ req: request }, payload)));
      } catch (error) {
        pending.delete(request);
        resolve([false, "macSteam is not running.", null]);
        return;
      }
      setTimeout(() => {
        if (pending.delete(request)) resolve([false, "macSteam did not respond.", null]);
      }, timeout);
    });
  }

  function toast(text, bad) {
    let el = document.getElementById("macsteam-properties-toast");
    if (!el) {
      el = document.createElement("div");
      el.id = "macsteam-properties-toast";
      el.style.cssText = "position:fixed;left:50%;bottom:28px;transform:translateX(-50%);" +
        "z-index:2147483647;max-width:560px;padding:9px 14px;border-radius:5px;background:#1b2838;" +
        "color:#c7d5e0;font:13px/1.4 'Motiva Sans',Arial,sans-serif;text-align:center;" +
        "box-shadow:0 2px 14px #000a;pointer-events:none;opacity:0;transition:opacity .2s;";
      document.documentElement.appendChild(el);
    }
    el.textContent = text;
    el.style.border = bad ? "1px solid #a34" : "1px solid #3a6a8a";
    el.style.opacity = "1";
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.style.opacity = "0"; }, 4600);
  }

  const SIDEBAR_LABELS = ["General", "Compatibility", "Updates", "Installed Files",
    "Game Versions & Betas", "Controller", "Game Recording", "Privacy", "Customization"];

  function leafIndex() {
    const index = new Map();
    for (const el of document.querySelectorAll("div,span,button,a")) {
      if (el.children.length !== 0) continue;
      const text = el.textContent.trim();
      if (!text || index.has(text)) continue;
      index.set(text, el);
    }
    return index;
  }

  function sidebarRowFrom(leaf) {
    let node = leaf;
    for (let depth = 0; depth < 6 && node; depth++) {
      const rect = node.getBoundingClientRect();
      // Keep matches inside the properties sidebar. Content headings are
      // indented and much wider, so they cannot be mistaken for a tab.
      if (rect.left < 180 && rect.width >= 120 && rect.width < 300 &&
          rect.height >= 20 && rect.height < 80) {
        return { node, rect };
      }
      node = node.parentElement;
    }
    return null;
  }

  function sidebarRows() {
    const leaves = leafIndex();
    const rows = [];
    for (const label of SIDEBAR_LABELS) {
      const leaf = leaves.get(label);
      if (!leaf) continue;
      const row = sidebarRowFrom(leaf);
      if (row) rows.push(row);
    }
    return rows;
  }

  function sidebarAnchor() {
    let anchor = null;
    for (const row of sidebarRows()) {
      if (!anchor || row.rect.bottom > anchor.rect.bottom) anchor = row;
    }
    return anchor;
  }

  function hideTab() {
    if (button) button.style.display = "none";
  }

  function ensureTab() {
    if (button) return button;
    button = document.createElement("button");
    button.type = "button";
    button.textContent = "Achievements";
    button.setAttribute("data-macsteam-achievements-tab", "1");
    button.style.cssText = "position:fixed;display:none;border:0;border-radius:0;" +
      "background:transparent;text-align:left;box-sizing:border-box;padding:0 24px;" +
      "cursor:pointer;pointer-events:auto;";
    button.addEventListener("mouseenter", () => {
      if (panelActive) return;
      button.style.background = "rgba(255,255,255,.10)";
      button.style.color = "#fff";
    });
    button.addEventListener("mouseleave", () => {
      if (panelActive) return;
      button.style.background = "transparent";
      button.style.color = "";
    });
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      showPanel();
    });
    layer.appendChild(button);
    return button;
  }

  function decorateTab() {
    const anchor = sidebarAnchor();
    if (!anchor) {
      hideTab();
      if (panelActive) hidePanel();
      return;
    }
    const tab = ensureTab();
    // Adopt Steam's own classes so the item matches the neighbouring tabs.
    const nativeClass = anchor.node.className || "";
    if (nativeClass && tab.dataset.nativeClass !== nativeClass) {
      tab.dataset.nativeClass = nativeClass;
      tab.className = nativeClass;
      tab.style.position = "fixed";
      tab.style.display = "none";
      tab.style.background = "transparent";
      tab.style.textAlign = "left";
      tab.style.pointerEvents = "auto";
    }
    tab.style.left = anchor.rect.left + "px";
    tab.style.top = anchor.rect.bottom + "px";
    tab.style.width = anchor.rect.width + "px";
    tab.style.height = Math.max(30, anchor.rect.height) + "px";
    tab.style.display = "block";
    if (panelActive) {
      dimNativeSelection();
      positionPanel();
    }
  }

  // ---------------------------------------------------------------------
  // Achievement list pane

  let panel = null;
  let panelActive = false;
  let panelAppID = 0;
  let panelAchievements = [];
  let panelSelection = new Set();
  let panelBoxes = [];
  let panelList = null;
  let panelCount = null;
  let panelSelectAll = null;
  let panelSelectNone = null;
  let panelClear = null;
  let panelUpload = null;
  let panelSave = null;
  let panelBusy = false;

  function smallButton(label, primary) {
    const element = document.createElement("button");
    element.type = "button";
    element.textContent = label;
    element.style.cssText = "flex:none;border-radius:2px;padding:5px 10px;" +
      "font:12px/1.25 'Motiva Sans',Arial,sans-serif;cursor:pointer;" +
      (primary
        ? "border:1px solid #66c0f4;background:#66c0f4;color:#0b1a26;"
        : "border:1px solid rgba(223,227,230,.18);background:rgba(59,63,72,.5);color:#dfe3e6;");
    if (primary) {
      element.addEventListener("mouseenter", () => { element.style.background = "#7fcdf7"; });
      element.addEventListener("mouseleave", () => { element.style.background = "#66c0f4"; });
    } else {
      element.addEventListener("mouseenter", () => { element.style.background = "rgba(80,85,96,.65)"; });
      element.addEventListener("mouseleave", () => { element.style.background = "rgba(59,63,72,.5)"; });
    }
    return element;
  }

  function selectedSidebarRow() {
    for (const row of sidebarRows()) {
      const background = getComputedStyle(row.node).backgroundColor;
      if (background && background !== "transparent" && background !== "rgba(0, 0, 0, 0)") {
        return { node: row.node, background };
      }
    }
    return null;
  }

  function dimNativeSelection() {
    if (nativeSelected && nativeSelected.node.isConnected) return;
    nativeSelected = null;
    const row = selectedSidebarRow();
    if (!row) return;
    nativeSelected = { node: row.node };
    row.node.setAttribute("data-macsteam-dimmed", "1");
  }

  function restoreNativeSelection() {
    if (!nativeSelected) return;
    nativeSelected.node.removeAttribute("data-macsteam-dimmed");
    nativeSelected = null;
  }

  function contentLeft() {
    const anchor = sidebarAnchor();
    if (anchor) {
      return Math.max(180, anchor.rect.left + anchor.rect.width);
    }
    return 350;
  }

  function positionPanel() {
    if (!panel) return;
    const left = contentLeft();
    panel.style.left = left + "px";
    panel.style.top = "0px";
    panel.style.width = Math.max(300, window.innerWidth - left) + "px";
    panel.style.height = window.innerHeight + "px";
  }

  function setPanelBusy(busy) {
    panelBusy = busy;
    for (const control of [panelSelectAll, panelSelectNone, panelClear,
      panelUpload, panelSave]) {
      if (!control) continue;
      control.disabled = busy;
      control.style.opacity = busy ? ".55" : "1";
      control.style.cursor = busy ? "default" : "pointer";
    }
  }

  function updatePanelCount() {
    if (!panelCount) return;
    panelCount.textContent = panelAchievements.length
      ? panelSelection.size + " of " + panelAchievements.length + " selected"
      : "";
  }

  function showPanelMessage(text) {
    panelList.textContent = text;
    panelList.style.padding = "12px";
    panelList.style.color = "#8b929a";
  }

  function renderPanelList() {
    panelList.textContent = "";
    panelList.style.padding = "0";
    panelList.style.color = "";
    panelBoxes = [];

    if (!panelAchievements.length) {
      showPanelMessage("No achievements were found for this game.");
      updatePanelCount();
      return;
    }

    panelAchievements.forEach((achievement, index) => {
      const row = document.createElement("label");
      row.style.cssText = "display:flex;align-items:flex-start;gap:9px;" +
        "padding:7px 12px;cursor:pointer;" +
        (index === panelAchievements.length - 1 ? "" : "border-bottom:1px solid rgba(255,255,255,.05);");
      row.addEventListener("mouseenter", () => { row.style.background = "rgba(255,255,255,.025)"; });
      row.addEventListener("mouseleave", () => { row.style.background = "transparent"; });

      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = panelSelection.has(achievement.id);
      input.style.cssText = "flex:none;margin:2px 0 0;accent-color:#66c0f4;";
      input.addEventListener("change", () => {
        if (input.checked) panelSelection.add(achievement.id);
        else panelSelection.delete(achievement.id);
        updatePanelCount();
      });

      const text = document.createElement("div");
      text.style.cssText = "display:flex;flex-direction:column;gap:1px;min-width:0;";
      const name = document.createElement("span");
      name.textContent = achievement.name || achievement.id;
      name.style.cssText = "font-size:13px;color:#dfe3e6;";
      text.appendChild(name);

      const detail = (achievement.description || "").trim();
      let description = detail;
      if (achievement.hidden) {
        description = detail
          ? detail + (/hidden achievement/i.test(detail) ? "" : "  ·  Hidden achievement")
          : "Hidden achievement";
      }
      if (description) {
        const desc = document.createElement("span");
        desc.textContent = description;
        desc.style.cssText = "font-size:12px;color:#8b929a;line-height:1.35;";
        text.appendChild(desc);
      }

      row.appendChild(input);
      row.appendChild(text);
      panelList.appendChild(row);
      panelBoxes.push(input);
    });

    updatePanelCount();
  }

  let panelTitleTimer = 0;

  async function loadPanel() {
    clearTimeout(panelTitleTimer);
    const title = (document.title || "").trim();
    if (!title) {
      // The sidebar renders before Steam fills in the window title. Wait for it
      // instead of leaving the pane stuck on "Loading achievements…".
      if (panelActive) panelTitleTimer = setTimeout(loadPanel, 150);
      return;
    }

    panelAppID = 0;
    panelAchievements = [];
    panelSelection = new Set();
    panelBoxes = [];
    panelUpload.checked = false;
    updatePanelCount();
    showPanelMessage("Loading achievements…");
    setPanelBusy(true);

    const [ok, message, data] = await send({ action: "list", title }, 60000);
    if (!panelActive || (document.title || "").trim() !== title) {
      setPanelBusy(false);
      return;
    }
    setPanelBusy(false);

    if (!ok || !data) {
      showPanelMessage(message || "macSteam could not load this game's achievements.");
      return;
    }

    panelAppID = data.appid;
    panelAchievements = data.achievements || [];
    panelSelection = new Set(
      panelAchievements.filter((achievement) => achievement.selected)
        .map((achievement) => achievement.id));
    renderPanelList();
  }

  function confirmClearProfile() {
    return new Promise((resolve) => {
      const bar = document.createElement("div");
      bar.style.cssText = "display:flex;align-items:center;gap:8px;padding:8px 12px;" +
        "margin-top:8px;border:1px solid #a34;background:rgba(163,68,68,.12);" +
        "border-radius:3px;font-size:13px;color:#dfe3e6;";
      const text = document.createElement("span");
      text.textContent = "Clear every achievement from your Steam profile?";
      text.style.flex = "1";
      const yes = smallButton("Clear Profile", true);
      const no = smallButton("Cancel", false);
      let done = false;
      const finish = (value) => {
        if (done) return;
        done = true;
        bar.remove();
        resolve(value);
      };
      yes.addEventListener("click", () => finish(true));
      no.addEventListener("click", () => finish(false));
      bar.appendChild(text);
      bar.appendChild(yes);
      bar.appendChild(no);
      panel.appendChild(bar);
    });
  }

  async function applySelection(upload, source) {
    if (panelBusy) return;
    if (!panelAppID) {
      toast("Achievements are still loading.", true);
      return;
    }
    if (upload && panelSelection.size === 0) {
      if (!(await confirmClearProfile())) return;
    }

    const label = source.textContent;
    source.textContent = upload ? "Uploading…" : "Saving…";
    setPanelBusy(true);
    const [ok, message] = await send({
      action: "save",
      appid: panelAppID,
      ids: [...panelSelection],
      upload: !!upload,
    }, upload ? 60000 : 20000);
    setPanelBusy(false);
    source.textContent = label;
    toast(message || (ok ? "Saved and applied."
      : "macSteam could not save the selection."), !ok);
  }

  async function clearPanelSelection() {
    if (panelBusy) return;
    const title = (document.title || "").trim();
    if (!title) return;

    const label = panelClear.textContent;
    panelClear.textContent = "Clearing…";
    setPanelBusy(true);
    const [ok, message] = await send({ action: "clear", title });
    setPanelBusy(false);
    panelClear.textContent = label;
    toast(message || (ok ? "Selection cleared."
      : "macSteam could not clear the selection."), !ok);

    if (ok) {
      panelSelection.clear();
      panelBoxes.forEach((box) => { box.checked = false; });
      panelUpload.checked = false;
      updatePanelCount();
    }
  }

  function buildPanel() {
    panel = document.createElement("div");
    panel.id = "macsteam-properties-pane";
    panel.style.cssText = "position:fixed;display:none;background:#171a21;color:#c7d5e0;" +
      "z-index:2147483640;overflow:hidden;box-sizing:border-box;padding:30px 24px 14px;" +
      "font:14px/1.45 'Motiva Sans',Arial,sans-serif;pointer-events:auto;" +
      "flex-direction:column;";

    const title = document.createElement("div");
    title.textContent = "Achievements";
    title.style.cssText = "font-size:32px;line-height:1.2;font-weight:600;" +
      "color:#fff;margin:0 0 6px;";
    panel.appendChild(title);

    const intro = document.createElement("div");
    intro.textContent = "Choose the achievements to mark as unlocked. " +
      "Changes are stored in Steam's local stats cache. " +
      "Ticking the profile box also locks the achievements you leave unselected on your Steam profile.";
    intro.style.cssText = "font-size:13px;color:#8b929a;line-height:1.45;" +
      "margin:0 0 12px;max-width:620px;";
    panel.appendChild(intro);

    const toolbar = document.createElement("div");
    toolbar.style.cssText = "display:flex;align-items:center;gap:6px;margin-bottom:8px;";
    panelSelectAll = smallButton("Select All", false);
    panelSelectNone = smallButton("Select None", false);
    panelCount = document.createElement("span");
    panelCount.style.cssText = "margin-left:auto;color:#8b929a;font-size:12px;";
    panelSelectAll.addEventListener("click", () => {
      if (panelBusy) return;
      panelBoxes.forEach((box) => { box.checked = true; });
      panelSelection = new Set(panelAchievements.map((achievement) => achievement.id));
      updatePanelCount();
    });
    panelSelectNone.addEventListener("click", () => {
      if (panelBusy) return;
      panelBoxes.forEach((box) => { box.checked = false; });
      panelSelection.clear();
      updatePanelCount();
    });
    toolbar.appendChild(panelSelectAll);
    toolbar.appendChild(panelSelectNone);
    toolbar.appendChild(panelCount);
    panel.appendChild(toolbar);

    panelList = document.createElement("div");
    panelList.style.cssText = "flex:1;min-height:120px;overflow-y:auto;" +
      "background:#23262e;border:1px solid rgba(255,255,255,.04);border-radius:2px;";
    showPanelMessage("Loading achievements…");
    panel.appendChild(panelList);

    const footer = document.createElement("div");
    footer.style.cssText = "display:flex;align-items:center;gap:8px;margin-top:12px;";

    const uploadGroup = document.createElement("div");
    uploadGroup.style.cssText = "display:flex;align-items:center;gap:6px;margin-right:auto;min-width:0;";
    panelUpload = document.createElement("input");
    panelUpload.type = "checkbox";
    panelUpload.id = "macsteam-properties-upload";
    panelUpload.style.cssText = "flex:none;margin:0;accent-color:#66c0f4;";
    const uploadLabel = document.createElement("label");
    uploadLabel.htmlFor = panelUpload.id;
    uploadLabel.textContent = "Upload to Steam profile (owned games only)";
    uploadLabel.title = "Set the selected achievements and lock the unselected ones on your Steam profile";
    uploadLabel.style.cssText = "font-size:12px;color:#8b929a;cursor:pointer;" +
      "white-space:nowrap;overflow:hidden;text-overflow:ellipsis;";
    uploadGroup.appendChild(panelUpload);
    uploadGroup.appendChild(uploadLabel);

    panelClear = smallButton("Clear Selection", false);
    panelSave = smallButton("Save", true);
    panelClear.addEventListener("click", clearPanelSelection);
    panelSave.addEventListener("click", () => applySelection(panelUpload.checked, panelSave));

    footer.appendChild(uploadGroup);
    footer.appendChild(panelClear);
    footer.appendChild(panelSave);
    panel.appendChild(footer);

    document.documentElement.appendChild(panel);
  }

  function showPanel() {
    if (!panel) buildPanel();
    if (panelActive) {
      positionPanel();
      return;
    }
    const selectedRow = selectedSidebarRow();
    const selectedBackground = selectedRow ? selectedRow.background : "rgb(61, 68, 80)";
    dimNativeSelection();
    panelActive = true;
    if (button) {
      button.style.background = selectedBackground;
      button.style.color = "#fff";
    }
    positionPanel();
    panel.style.display = "flex";
    loadPanel();
  }

  function hidePanel() {
    panelActive = false;
    clearTimeout(panelTitleTimer);
    if (panel) panel.style.display = "none";
    restoreNativeSelection();
    if (button) {
      button.style.background = "transparent";
      button.style.color = "";
    }
  }

  function onDocumentClick(event) {
    if (!panelActive || !panel) return;
    if (panel.contains(event.target) || event.target === button) return;
    const rect = event.target.getBoundingClientRect();
    if (rect.left < panel.getBoundingClientRect().left - 80) hidePanel();
  }

  let timer = 0;
  function schedule() {
    if (timer) return;
    timer = setTimeout(() => { timer = 0; decorateTab(); }, 80);
  }

  function onTabClick(event) {
    const target = event.target;
    const tab = target && target.closest
      ? target.closest("[data-macsteam-achievements-tab]")
      : null;
    if (!tab) return;
    event.preventDefault();
    event.stopPropagation();
    showPanel();
  }

  document.addEventListener("click", onDocumentClick, true);
  document.addEventListener("click", onTabClick, true);

  const observer = new MutationObserver(schedule);
  observer.observe(document.documentElement,
    { childList: true, subtree: true, attributes: false });
  window.addEventListener("scroll", schedule, true);
  window.addEventListener("resize", schedule);
  const interval = setInterval(decorateTab, 160);

  window.__macsteamPropertiesTeardown = () => {
    clearInterval(interval);
    clearTimeout(timer);
    clearTimeout(panelTitleTimer);
    observer.disconnect();
    window.removeEventListener("scroll", schedule, true);
    window.removeEventListener("resize", schedule);
    document.removeEventListener("click", onDocumentClick, true);
    document.removeEventListener("click", onTabClick, true);
    if (panelActive) hidePanel();
    document.querySelectorAll("[data-macsteam-dimmed]")
      .forEach((el) => el.removeAttribute("data-macsteam-dimmed"));
    pending.clear();
    layer.remove();
    delete window.macsteamAchievementResult;
    delete window.__macsteamPropertiesInstalled;
    delete window.__macsteamPropertiesTeardown;
  };

  decorateTab();
})();

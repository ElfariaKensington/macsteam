(() => {
    'use strict';
    if (location.protocol !== 'https:' || location.hostname !== 'store.steampowered.com' || window.__macsteamHubcap) return;
    let appID = 0;
    const pending = new Map();
    let sequence = 0;
    let state = 'checking';
    let busy = false;
    let fixBusy = false;
    let root, button, message, titlePrefix, fixesRoot;
    const bridge = window.macsteamHubcap;
    if (typeof bridge !== 'function') return;
    window.__macsteamHubcap = {
        reply(id, result) {
            const request = pending.get(id);
            if (!request) return;
            pending.delete(id);
            clearTimeout(request.timer);
            request.resolve(result);
        }
    };
    function request(action, fixID) {
        return new Promise(resolve => {
            const id = `${appID}:${++sequence}`;
            const timer = setTimeout(() => {
                pending.delete(id);
                resolve({ error: 'macSteam did not respond. Open macSteam Config and try again.' });
            }, 90000);
            pending.set(id, { resolve, timer });
            bridge(JSON.stringify({ id, appID, action, fixID }));
        });
    }
    function render() {
        if (!button) return;
        message.hidden = !message.textContent;
        titlePrefix.textContent = state === 'ready' ? 'Ready to install with ' :
            state === 'checking' ? 'Checking Steam library for ' : 'Add to library with ';
        button.disabled = busy || state === 'checking';
        button.querySelector('span').textContent = busy ? 'Adding to library…' :
            state === 'ready' ? 'Install' : state === 'checking' ? 'Checking library…' : 'Add to library';
        button.setAttribute('aria-busy', String(busy));
    }
    async function refresh() {
        const requestedApp = appID;
        const result = await request('status');
        if (requestedApp !== appID) return;
        if (result.error) {
            state = 'add';
            message.textContent = result.error;
        } else {
            state = result.ready ? 'ready' : 'add';
            message.textContent = '';
        }
        render();
    }
    // Game fixes: a second card listing LuaTools fixes for this game.
    function removeFixes() {
        fixesRoot?.remove();
        fixesRoot = null;
    }
    function actionButton(label, onClick) {
        const el = document.createElement('button');
        el.type = 'button';
        el.className = 'btn_grey_steamui btn_small';
        el.style.cssText = 'border:0;cursor:pointer;font:inherit;margin-left:6px';
        const text = document.createElement('span');
        text.textContent = label;
        el.appendChild(text);
        el.addEventListener('click', onClick);
        return el;
    }
    function renderFixes(result, statusText) {
        if (!root?.isConnected) return;
        removeFixes();
        if (result.error || !result.fixes?.length) return;
        fixesRoot = document.createElement('div');
        fixesRoot.id = 'macsteam-fixes';
        fixesRoot.className = 'game_area_purchase_game';
        const title = document.createElement('h2');
        title.className = 'title';
        title.textContent = 'Game fixes with macSteam';
        fixesRoot.appendChild(title);
        const status = document.createElement('div');
        status.setAttribute('role', 'status');
        status.setAttribute('aria-live', 'polite');
        status.style.cssText = 'font-size:12px;color:#acb2b8;margin:6px 0';
        const needsGame = !result.gameInstalled && result.fixes.some(f => f.hasFix);
        status.textContent = statusText ||
            (needsGame ? 'Game not installed: "Install fix" needs it in your Steam library folder. Manifests can be installed now.' : '');
        status.hidden = !status.textContent;
        fixesRoot.appendChild(status);
        for (const fix of result.fixes) {
            const row = document.createElement('div');
            row.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:12px;padding:8px 0;border-top:1px solid rgba(198,212,223,.12)';
            const info = document.createElement('div');
            const name = document.createElement('div');
            name.textContent = fix.title;
            name.style.cssText = 'color:#fff;font-size:14px';
            info.appendChild(name);
            if (fix.description) {
                const desc = document.createElement('div');
                desc.textContent = fix.description;
                desc.style.cssText = 'color:#acb2b8;font-size:12px;margin-top:2px';
                info.appendChild(desc);
            }
            const actions = document.createElement('div');
            actions.style.cssText = 'white-space:nowrap';
            const run = async (action, button) => {
                if (fixBusy) return;
                fixBusy = true;
                const requestedApp = appID;
                const wasDisabled = new Set([...fixesRoot.querySelectorAll('button')].filter(b => b.disabled));
                fixesRoot.querySelectorAll('button').forEach(b => { b.disabled = true; });
                status.hidden = false;
                status.textContent = 'Working…';
                const reply = await request(action, fix.id);
                fixBusy = false;
                if (requestedApp !== appID) return;
                if (reply.error) {
                    fixesRoot.querySelectorAll('button').forEach(b => { b.disabled = wasDisabled.has(b); });
                    status.textContent = reply.error;
                    return;
                }
                renderFixes(reply, reply.message);
            };
            if (fix.hasManifest) {
                const b = actionButton(result.manifestInstalled ? 'Manifest installed' : 'Install manifest',
                    () => run('fix-manifest'));
                b.disabled = !!result.manifestInstalled;
                actions.appendChild(b);
            }
            if (fix.hasFix && !fix.applied) {
                const b = actionButton('Install fix', () => run('fix-install'));
                b.disabled = !result.gameInstalled;
                actions.appendChild(b);
            }
            if (fix.applied) {
                actions.appendChild(actionButton('Undo fix', () => run('fix-undo')));
            }
            row.append(info, actions);
            fixesRoot.appendChild(row);
        }
        root.after(fixesRoot);
    }
    async function loadFixes() {
        const requestedApp = appID;
        const result = await request('fixes');
        if (requestedApp !== appID) return;
        renderFixes(result);
    }
    async function clicked(event) {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (busy) return;
        if (state === 'ready') {
            // Steam handles its own installation dialog and library location selection.
            location.href = `steam://install/${appID}`;
            return;
        }
        busy = true;
        message.textContent = '';
        render();
        const requestedApp = appID;
        const result = await request('add');
        if (requestedApp !== appID) return;
        busy = false;
        if (result.ready) {
            state = 'ready';
            message.textContent = '';
        } else {
            state = 'add';
            message.textContent = result.error || 'Steam has not confirmed the library refresh. Try again.';
        }
        render();
    }
    function mount() {
        const match = location.pathname.match(/^\/app\/([1-9][0-9]*)(?:\/|$)/);
        const id = match ? Number(match[1]) : 0;
        const nextApp = Number.isSafeInteger(id) && id <= 2147483647 ? id : 0;
        if (nextApp !== appID) {
            root?.remove();
            root = null;
            removeFixes();
            fixBusy = false;
            appID = nextApp;
            busy = false;
            state = 'checking';
        }
        if (!appID || root?.isConnected) return;
        const host = document.querySelector('#game_area_purchase, .game_area_purchase');
        if (!host) return;
        root = document.createElement('div');
        root.id = 'macsteam-hubcap-purchase';
        root.className = 'game_area_purchase_game';
        const title = document.createElement('h2');
        title.className = 'title';
        titlePrefix = document.createTextNode('Add to library with ');
        const brand = document.createElement('span');
        brand.textContent = 'macSteam';
        brand.style.cssText = 'display:inline-block;margin-left:6px;padding:2px 8px;border:1px solid rgba(198,212,223,.28);border-radius:999px;color:#c6d4df;font-size:.72em;line-height:1.4;vertical-align:2px';
        title.append(titlePrefix, brand);
        const actions = document.createElement('div');
        actions.className = 'game_purchase_action';
        const background = document.createElement('div');
        background.className = 'game_purchase_action_bg';
        const buttonContainer = document.createElement('div');
        buttonContainer.className = 'btn_addtocart';
        button = document.createElement('button');
        button.type = 'button';
        button.className = 'btn_green_steamui btn_medium';
        button.style.cssText = 'border:0;cursor:pointer;font:inherit';
        button.appendChild(document.createElement('span'));
        button.addEventListener('click', clicked);
        message = document.createElement('div');
        message.setAttribute('role', 'status');
        message.setAttribute('aria-live', 'polite');
        message.style.cssText = 'font-size:12px;color:#acb2b8;margin-top:8px;max-width:75%';
        buttonContainer.appendChild(button);
        background.appendChild(buttonContainer);
        actions.appendChild(background);
        root.append(title, message, actions);
        host.prepend(root);
        render();
        if (!busy) void refresh();
        void loadFixes();
    }
    new MutationObserver(mount).observe(document, { childList: true, subtree: true });
    window.addEventListener('popstate', mount);
    window.navigation?.addEventListener('currententrychange', mount);
    mount();
})();

(() => {
    'use strict';
    // In-Steam game fixes: adds a "Game fixes with macSteam" card above the purchase
    // options on store pages. All work happens in the macSteam app via the bridge.
    if (location.protocol !== 'https:' ||
        location.hostname !== 'store.steampowered.com' ||
        window.__macsteamStoreButton) return;

    const bridge = window.macsteamHubcap;
    if (typeof bridge !== 'function') return;

    let appID = 0;
    let fixesRoot = null;
    let fixBusy = false;
    let lastFixes = null;
    let lastFixesApp = 0;
    const pending = new Map();
    let sequence = 0;

    function request(action, fixID) {
        return new Promise(resolve => {
            const id = `${appID}:${Date.now()}:${++sequence}`;
            const timeout = action === 'fixes' ? 20000 : 300000;
            const timer = setTimeout(() => {
                pending.delete(id);
                resolve({ error: 'macSteam did not respond. Open macSteam Config and try again.' });
            }, timeout);
            pending.set(id, { resolve, timer });
            try {
                bridge(JSON.stringify({ id, appID, action, fixID }));
            } catch (error) {
                clearTimeout(timer);
                pending.delete(id);
                resolve({ error: 'macSteam could not reach Steam. Restart Steam and try again.' });
            }
        });
    }

    // Game fixes: a second card listing LuaTools fixes for this game.
    function removeFixes() {
        fixesRoot?.remove();
        fixesRoot = null;
        lastFixes = null;
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
        removeFixes();
        lastFixes = result;
        lastFixesApp = appID;
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
            const run = async (action) => {
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
        const purchase = document.querySelector('#game_area_purchase, .game_area_purchase');
        if (!purchase) { fixesRoot = null; return; }
        purchase.prepend(fixesRoot);
    }
    async function loadFixes() {
        const requestedApp = appID;
        const result = await request('fixes');
        if (requestedApp !== appID) return;
        renderFixes(result);
    }
    function mount() {
        const match = location.pathname.match(/^\/app\/([1-9][0-9]*)(?:\/|$)/);
        const nextApp = match ? Number(match[1]) : 0;
        if (nextApp !== appID) {
            removeFixes();
            fixBusy = false;
            appID = nextApp;
            if (appID) void loadFixes();
        } else if (appID && lastFixes && lastFixesApp === appID && !fixesRoot?.isConnected) {
            renderFixes(lastFixes);
        }
    }

    // The bridge calls this after (re)attaching to an existing page, whose first
    // request may have fired before the new CDP session was ready.
    window.__macsteamRefresh = function () {
        if (appID && !fixBusy) void loadFixes();
    };

    // CDP replies arrive through this global; the bridge evaluates
    // window.__macsteamHubcap.reply(...), which forwards to the pending map.
    window.__macsteamHubcap = {
        reply(id, result) {
            const waiter = pending.get(id);
            if (!waiter) return;
            clearTimeout(waiter.timer);
            pending.delete(id);
            waiter.resolve(result || {});
        }
    };

    window.addEventListener('popstate', () => setTimeout(mount, 50));
    window.navigation?.addEventListener('currententrychange', () => setTimeout(mount, 50));
    setInterval(mount, 1000);
    window.__macsteamStoreButton = true;
    mount();
})();

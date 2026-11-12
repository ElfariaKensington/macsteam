(() => {
    'use strict';
    if (location.protocol !== 'https:' || location.hostname !== 'store.steampowered.com' || window.__macsteamHubcap) return;
    let appID = 0;
    const pending = new Map();
    let sequence = 0;
    let state = 'checking';
    let busy = false;
    let root, button, message, titlePrefix;
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
    function request(action) {
        return new Promise(resolve => {
            const id = `${appID}:${++sequence}`;
            const timer = setTimeout(() => {
                pending.delete(id);
                resolve({ error: 'macSteam did not respond. Open macSteam Config and try again.' });
            }, 90000);
            pending.set(id, { resolve, timer });
            bridge(JSON.stringify({ id, appID, action }));
        });
    }
    function render() {
        if (!button) return;
        // Already installed: nothing to add or install, so the card is not shown at all.
        root.style.display = state === 'installed' ? 'none' : '';
        if (state === 'installed') return;
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
            state = result.installed ? 'installed' : result.ready ? 'ready' : 'add';
            message.textContent = '';
        }
        render();
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
    }
    new MutationObserver(mount).observe(document, { childList: true, subtree: true });
    window.addEventListener('popstate', mount);
    // Returning from Steam's install dialog (or an uninstall) must update the card.
    window.addEventListener('focus', () => { if (appID && root?.isConnected && !busy) void refresh(); });
    window.navigation?.addEventListener('currententrychange', mount);
    mount();
})();

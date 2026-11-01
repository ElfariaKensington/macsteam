(() => {
    'use strict';
    if (location.protocol !== 'https:' || location.hostname !== 'store.steampowered.com' || window.__macsteamHubcap) return;
    let appID = 0;
    const pending = new Map();
    let sequence = 0;
    let state = 'checking';
    let busy = false;
    let root, button, message;
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
            message.textContent = result.configured && !result.ready ?
                'Saved in macSteam. Click to activate in Steam.' : '';
        }
        render();
    }
    async function clicked(event) {
        event.preventDefault();
        if (busy) return;
        if (state === 'ready') {
            // Steam handles its own installation dialog and library location selection.
            location.href = `steam://install/${appID}`;
            return;
        }
        busy = true;
        message.textContent = 'Downloading Lua and manifests, then refreshing Steam…';
        render();
        const requestedApp = appID;
        const result = await request('add');
        if (requestedApp !== appID) return;
        busy = false;
        if (result.ready) {
            state = 'ready';
            message.textContent = 'Added to your Steam library. Ready to install.';
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
        const title = document.createElement('h1');
        title.textContent = 'macSteam';
        const actions = document.createElement('div');
        actions.className = 'game_purchase_action';
        const background = document.createElement('div');
        background.className = 'game_purchase_action_bg';
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
        background.appendChild(button);
        actions.appendChild(background);
        root.append(title, message, actions);
        host.prepend(root);
        render();
        if (!busy) void refresh();
    }
    new MutationObserver(mount).observe(document, { childList: true, subtree: true });
    window.addEventListener('popstate', mount);
    window.navigation?.addEventListener('currententrychange', mount);
    mount();
})();

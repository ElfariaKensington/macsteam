(() => {
    'use strict';
    if (location.protocol !== 'https:' ||
        location.hostname !== 'store.steampowered.com' ||
        window.__macsteamStoreButton) return;

    const bridge = window.macsteamHubcap;
    if (typeof bridge !== 'function') return;

    let appID = 0;
    let state = 'checking';
    let busy = false;
    let root = null;
    let button = null;
    let message = '';
    const pending = new Map();
    let sequence = 0;
    let mountedFor = '';

    function request(action) {
        return new Promise(resolve => {
            const id = `${appID}:${Date.now()}:${++sequence}`;
            const timeout = action === 'status' ? 20000 :
                action === 'restart' ? 30000 : 300000;
            const timer = setTimeout(() => {
                pending.delete(id);
                resolve({ error: 'macSteam did not respond. Open macSteam Config and try again.' });
            }, timeout);
            pending.set(id, { resolve, timer });
            try {
                bridge(JSON.stringify({ id, appID, action }));
            } catch (error) {
                clearTimeout(timer);
                pending.delete(id);
                resolve({ error: 'macSteam could not reach Steam. Restart Steam and try again.' });
            }
        });
    }

    function toast(text, isError) {
        if (!text) return;
        let host = document.getElementById('macsteam-toast');
        if (!host) {
            host = document.createElement('div');
            host.id = 'macsteam-toast';
            host.setAttribute('role', 'status');
            host.setAttribute('aria-live', 'polite');
            host.style.cssText = 'position:fixed;right:20px;bottom:20px;z-index:99999;' +
                'max-width:420px;padding:10px 14px;border-radius:6px;font-size:13px;' +
                'line-height:1.4;color:#c6d4df;background:rgba(23,29,37,.96);' +
                'border:1px solid rgba(198,212,223,.25);box-shadow:0 6px 24px rgba(0,0,0,.45)';
            document.body.appendChild(host);
        }
        host.textContent = text;
        host.style.borderColor = isError ? 'rgba(255,107,107,.7)' : 'rgba(198,212,223,.25)';
        host.style.color = isError ? '#ffb3b3' : '#c6d4df';
        host.hidden = false;
        clearTimeout(host.__macsteamTimer);
        host.__macsteamTimer = setTimeout(() => { host.hidden = true; }, 8000);
    }

    function render() {
        if (!button) return;
        const label = busy ? (state === 'restart' ? 'Restarting Steam…' : 'Adding to library…') :
            state === 'ready' ? 'Install with Steam' :
            state === 'restart' ? 'Restart Steam' :
            state === 'checking' ? 'Checking macSteam…' : 'Add via macSteam';
        const span = button.querySelector('span');
        if (span) span.textContent = label;
        button.title = message || label;
        button.setAttribute('data-tooltip-text', message || label);
        button.style.opacity = state === 'checking' ? '.65' : '1';
        button.style.pointerEvents = state === 'checking' ? 'none' : 'auto';
        button.setAttribute('aria-busy', String(busy));
    }

    async function refresh() {
        const requested = appID;
        state = 'checking';
        message = '';
        render();
        const result = await request('status');
        if (requested !== appID) return;
        if (result.error) {
            state = 'add';
            message = result.error;
            toast(result.error, true);
        } else if (result.ready) {
            state = 'ready';
        } else {
            state = 'add';
            if (result.name) message = `Hubcap has ${result.name}.`;
        }
        render();
    }

    async function clicked(event) {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (busy || state === 'checking') return;
        if (state === 'ready') {
            window.location.href = `steam://install/${appID}`;
            return;
        }
        busy = true;
        message = '';
        render();
        const requested = appID;
        if (state === 'restart') {
            const restarted = await request('restart');
            if (requested !== appID) return;
            if (restarted.error) {
                busy = false;
                message = restarted.error;
                toast(message, true);
                render();
            } else {
                toast('Restarting Steam…');
            }
            return;
        }
        const result = await request('add');
        if (requested !== appID) return;
        busy = false;
        if (result.ready) {
            // A library refresh is armed, but Steam only re-reads it reliably on a
            // fresh launch. Make that the obvious next action.
            state = 'restart';
            message = '';
            toast(result.activated
                ? 'Added to macSteam. Restart Steam to finish adding it to your library.'
                : 'Added to macSteam. Restart Steam to see it in your library.');
        } else {
            state = 'add';
            message = result.error || 'Steam has not confirmed the library refresh. Try again.';
            toast(message, true);
        }
        render();
    }

    // The bridge calls this after (re)attaching to an existing page. The page may have
    // fired its first status request before the new CDP session was ready, so retry it.
    window.__macsteamRefresh = function () {
        if (!appID || busy) return;
        void refresh();
    };

    function headerHost() {
        return document.querySelector('.apphub_OtherSiteInfo') ||
            document.querySelector('.steamdb-buttons') ||
            document.querySelector('[data-steamdb-buttons]') ||
            document.querySelector('#game_area_purchase, .game_area_purchase');
    }

    function mount() {
        const match = location.pathname.match(/^\/app\/([1-9][0-9]*)(?:\/|$)/);
        const nextApp = match ? Number(match[1]) : 0;
        if (nextApp !== appID) {
            root?.remove();
            root = null;
            button = null;
            appID = nextApp;
            state = 'checking';
            busy = false;
            message = '';
            mountedFor = '';
        }
        if (!appID || root?.isConnected) return;
        const host = headerHost();
        if (!host) return;

        root = document.createElement('span');
        root.id = 'macsteam-store-button';
        root.style.cssText = 'display:inline-flex;align-items:center;margin-left:6px';

        button = document.createElement('a');
        button.href = '#';
        const reference = host.querySelector('a');
        button.className = reference && reference.className
            ? reference.className
            : 'btnv6_blue_hoverfade btn_medium';
        button.classList.add('macsteam-store-button');
        button.style.cssText = 'cursor:pointer';
        button.appendChild(document.createElement('span'));
        button.addEventListener('click', clicked);
        root.appendChild(button);

        host.appendChild(root);
        mountedFor = String(appID);
        render();
        void refresh();
    }

    // CDP replies arrive through this global; the bridge evaluates
    // window.__macsteamHubcap.reply(...), which forwards to the same pending map.
    window.__macsteamHubcap = {
        reply(id, result) {
            const waiter = pending.get(id);
            if (!waiter) return;
            clearTimeout(waiter.timer);
            pending.delete(id);
            waiter.resolve(result || {});
        }
    };

    if (!window.__macsteamStoreObserver) {
        window.__macsteamStoreObserver = new MutationObserver(() => {
            if (!root?.isConnected) mount();
        });
        // At document-start <html> does not exist yet; Document itself is always a valid
        // MutationObserver target and still sees the whole subtree.
        window.__macsteamStoreObserver.observe(document, {
            childList: true,
            subtree: true,
        });
    }
    window.addEventListener('popstate', () => { mountedFor = ''; setTimeout(mount, 50); });
    window.navigation?.addEventListener('currententrychange', () => {
        mountedFor = '';
        setTimeout(mount, 50);
    });
    setInterval(() => {
        if (!appID || !root?.isConnected || mountedFor !== String(appID)) mount();
    }, 1000);
    window.__macsteamStoreButton = true;
    mount();
})();

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('macsteam-app/Sources/MacsteamApp/Resources/hubcap-store.js', 'utf8');

class Element {
    constructor(tag) { this.tag = tag; this.children = []; this.listeners = {}; this.style = {}; this.isConnected = false; }
    append(...children) { this.children.push(...children); children.forEach(c => { c.isConnected = this.isConnected; c.parent = this; }); }
    appendChild(child) { this.append(child); return child; }
    prepend(child) { this.children.unshift(child); child.isConnected = true; child.parent = this; }
    remove() { this.isConnected = false; if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1); }
    setAttribute(key, value) { this[key] = value; }
    addEventListener(name, action) { this.listeners[name] = action; }
    replaceWith(child) {
        const at = this.parent.children.indexOf(this);
        this.parent.children.splice(at, 1, child);
        child.parent = this.parent; child.isConnected = this.isConnected; this.isConnected = false;
    }
    insertBefore(child, next) {
        this.children.splice(this.children.indexOf(next), 0, child);
        child.parent = this; child.isConnected = this.isConnected;
    }
    querySelector(selector) {
        const matches = c => selector.startsWith('.') ? c.className?.split(' ').includes(selector.slice(1).split(':')[0]) : c.tag === selector;
        return this.children.find(matches) || this.children.map(c => c.querySelector(selector)).find(Boolean);
    }
}
function page(url = 'https://store.steampowered.com/app/620/Portal_2/') {
    const host = new Element('purchase');
    host.isConnected = true;
    const card = new Element('div'); card.className = 'game_area_purchase_game';
    const title = new Element('h2'); title.textContent = 'Buy Portal 2';
    const platforms = new Element('platforms');
    const original = new Element('div'); original.className = 'game_purchase_action';
    card.append(title, platforms, original); host.append(card);
    const requests = [];
    let mutation;
    const location = new URL(url);
    const events = {};
    const window = {
        macsteamHubcap: text => {
            const request = JSON.parse(text);
            // Builds that also carry the game-fixes card ask separately; this test is about the
            // Add/Install card, so those requests are answered with "no fixes".
            if (request.action === 'fixes') { setImmediate(() => window.__macsteamHubcap.reply(request.id, { fixes: [] })); return; }
            requests.push(request);
        },
        addEventListener(name, fn) { (events[name] ||= []).push(fn); } };
    const document = { documentElement: null, querySelector: () => host, createElement: tag => new Element(tag), createTextNode: text => { const node = new Element('#text'); node.textContent = text; return node; } };
    const context = vm.createContext({ window, document, location, setTimeout, clearTimeout,
        MutationObserver: class { constructor(callback) { mutation = callback; } observe(target) { assert.equal(target, document); } } });
    vm.runInContext(source, context);
    return { host, title, platforms, original, requests, window, events, location, context, mutation: () => mutation?.(),
        reply: result => { const request = requests.shift(); assert.ok(request); window.__macsteamHubcap.reply(request.id, result); } };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
(async () => {
    const p = page();
    assert.equal(p.requests[0].action, 'status');
    assert.equal(p.requests[0].appID, 620);
    p.reply({ configured: false, ready: false });
    await flush();
    let button = p.host.children[0].querySelector('button');
    assert.equal(button.querySelector('span').textContent, 'Add to library');
    assert.equal(p.host.children.length, 2, 'macSteam card is added above the untouched Steam purchase card');
    assert.equal(p.host.children[1].children[0], p.title, 'original game title retained');
    assert.equal(p.host.children[1].children[1], p.platforms, 'original platform icons retained');
    let stopped = false;
    const adding = button.listeners.click({ preventDefault() {}, stopImmediatePropagation() { stopped = true; } });
    assert.ok(stopped, 'purchase click must not reach Steam purchase handlers');
    assert.equal(p.requests[0].action, 'add');
    assert.equal(button.disabled, true);
    await button.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    assert.equal(p.requests.length, 1, 'double clicks cannot duplicate downloads');
    p.reply({ ready: true });
    await adding;
    assert.equal(button.querySelector('span').textContent, 'Install');
    assert.equal(p.location.href, 'https://store.steampowered.com/app/620/Portal_2/', 'adding must keep the current Store document');
    await button.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    assert.equal(p.location.href, 'steam://install/620');

    const failed = page();
    failed.reply({ ready: false }); await flush();
    button = failed.host.children[0].querySelector('button');
    const operation = button.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    failed.reply({ error: 'Download failed' }); await operation;
    assert.equal(button.querySelector('span').textContent, 'Add to library');
    assert.equal(button.disabled, false);
    assert.equal(failed.host.children[0].children.find(c => c.role === 'status').textContent, 'Download failed');
    vm.runInContext(source, failed.context);
    assert.equal(failed.host.children.length, 2, 'reinjection must not duplicate controls');
    failed.location.pathname = '/app/400/Portal/';
    failed.mutation();
    assert.equal(failed.requests[0].appID, 400, 'same-document navigation updates the AppID');
    failed.reply({ ready: true }); await flush();
    assert.equal(failed.host.children[0].querySelector('button').querySelector('span').textContent, 'Install');
    // Already-installed games must not show "Add to library" or "Ready to install".
    const owned = page();
    owned.reply({ configured: true, ready: true, installed: true }); await flush();
    const ownedCard = owned.host.children[0];
    assert.equal(ownedCard.style.display, 'none', 'installed game hides the macSteam card');
    assert.notEqual(ownedCard.querySelector('button').querySelector('span').textContent, 'Install');
    const text = el => (el.textContent ?? '') + (el.children || []).map(text).join('');
    assert.ok(!/Ready to install/.test(text(ownedCard)) || ownedCard.style.display === 'none', 'no visible "Ready to install" text');
    owned.events.focus.forEach(fn => fn());
    assert.equal(owned.requests[0].action, 'status', 'focus re-checks the install state');
    owned.reply({ configured: true, ready: true, installed: false }); await flush();
    assert.equal(ownedCard.style.display, '', 'uninstalling brings the card back');
    assert.equal(ownedCard.querySelector('button').querySelector('span').textContent, 'Install');
    owned.events.focus.forEach(fn => fn());
    owned.reply({ configured: true, ready: true, installed: true }); await flush();
    assert.equal(ownedCard.style.display, 'none', 'installing hides the card again');
    const foreign = page('https://example.com/app/620/');
    assert.equal(foreign.requests.length, 0);
    assert.equal(foreign.host.children[0].querySelector('.game_purchase_action'), foreign.original);
    const home = page('https://store.steampowered.com/');
    assert.equal(home.requests.length, 0);
    home.location.pathname = '/app/1234567/'; home.mutation();
    assert.equal(home.requests[0].appID, 1234567);
    home.reply({ ready: false }); await flush();
    console.log('Store UI: passed (Add → Install, installed games hidden, native install URL, duplicate clicks, errors, reinjection, navigation, origin)');
})().catch(error => { console.error(error); process.exit(1); });

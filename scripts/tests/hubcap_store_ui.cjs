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
    querySelector(tag) { return this.children.find(c => c.tag === tag) || this.children.map(c => c.querySelector(tag)).find(Boolean); }
}
function page(url = 'https://store.steampowered.com/app/620/Portal_2/') {
    const host = new Element('purchase');
    const requests = [];
    let mutation;
    const location = new URL(url);
    const window = { macsteamHubcap: text => requests.push(JSON.parse(text)), addEventListener() {} };
    const document = { documentElement: null, querySelector: () => host, createElement: tag => new Element(tag) };
    const context = vm.createContext({ window, document, location, setTimeout, clearTimeout,
        MutationObserver: class { constructor(callback) { mutation = callback; } observe(target) { assert.equal(target, document); } } });
    vm.runInContext(source, context);
    return { host, requests, window, location, context, mutation: () => mutation?.(),
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
    const adding = button.listeners.click({ preventDefault() {} });
    assert.equal(p.requests[0].action, 'add');
    assert.equal(button.disabled, true);
    await button.listeners.click({ preventDefault() {} });
    assert.equal(p.requests.length, 1, 'double clicks cannot duplicate downloads');
    p.reply({ ready: true });
    await adding;
    assert.equal(button.querySelector('span').textContent, 'Install');
    await button.listeners.click({ preventDefault() {} });
    assert.equal(p.location.href, 'steam://install/620');

    const failed = page();
    failed.reply({ ready: false }); await flush();
    button = failed.host.children[0].querySelector('button');
    const operation = button.listeners.click({ preventDefault() {} });
    failed.reply({ error: 'Download failed' }); await operation;
    assert.equal(button.querySelector('span').textContent, 'Add to library');
    assert.equal(button.disabled, false);
    assert.equal(failed.host.children[0].querySelector('div').textContent, 'Download failed');
    vm.runInContext(source, failed.context);
    assert.equal(failed.host.children.length, 1, 'reinjection must not duplicate controls');
    failed.location.pathname = '/app/400/Portal/';
    failed.mutation();
    assert.equal(failed.requests[0].appID, 400, 'same-document navigation updates the AppID');
    failed.reply({ ready: true }); await flush();
    assert.equal(failed.host.children.at(-1).querySelector('button').querySelector('span').textContent, 'Install');
    const foreign = page('https://example.com/app/620/');
    assert.equal(foreign.requests.length, 0);
    assert.equal(foreign.host.children.length, 0);
    const home = page('https://store.steampowered.com/');
    assert.equal(home.requests.length, 0);
    home.location.pathname = '/app/1234567/'; home.mutation();
    assert.equal(home.requests[0].appID, 1234567);
    home.reply({ ready: false }); await flush();
    console.log('Store UI: passed (Add → Install, native install URL, duplicate clicks, errors, reinjection, navigation, origin)');
})().catch(error => { console.error(error); process.exit(1); });

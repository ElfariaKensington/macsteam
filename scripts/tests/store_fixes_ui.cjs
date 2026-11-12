// Store-page game-fixes card: which buttons show for not applied / applied / drifted fixes,
// and the privacy-settings button when macOS blocks the write.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('macsteam-app/Sources/MacsteamApp/Resources/hubcap-store.js', 'utf8');

class Element {
    constructor(tag) { this.tag = tag; this.children = []; this.listeners = {}; this.style = {}; this.isConnected = false; }
    append(...kids) { kids.forEach(k => { this.children.push(k); k.parent = this; k.isConnected = this.isConnected; }); }
    appendChild(kid) { this.append(kid); return kid; }
    prepend(kid) { this.children.unshift(kid); kid.parent = this; kid.isConnected = this.isConnected; }
    remove() { this.isConnected = false; if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1); }
    setAttribute(key, value) { this[key] = value; }
    addEventListener(name, fn) { this.listeners[name] = fn; }
    querySelectorAll(tag) { const out = []; const walk = n => { if (n.tag === tag) out.push(n); (n.children || []).forEach(walk); }; walk(this); return out; }
}
const flush = () => new Promise(resolve => setImmediate(resolve));

function page() {
    const events = {}, sent = [];
    const host = new Element('purchase'); host.isConnected = true;
    const window = { macsteamHubcap: text => sent.push(JSON.parse(text)), addEventListener(n, f) { (events[n] ||= []).push(f); } };
    const document = { querySelector: () => host, createElement: t => new Element(t),
        createTextNode: t => { const n = new Element('#text'); n.textContent = t; return n; } };
    const context = vm.createContext({ window, document, location: new URL('https://store.steampowered.com/app/620/Portal_2/'),
        setTimeout, clearTimeout, setInterval: () => 0 });
    vm.runInContext(source, context);
    const answer = async (action, reply) => {
        const i = sent.findIndex(r => r.action === action);
        assert.ok(i >= 0, `expected a ${action} request, saw ${JSON.stringify(sent.map(r => r.action))}`);
        const [request] = sent.splice(i, 1);
        window.__macsteamHubcap.reply(request.id, reply); await flush();
    };
    const card = () => host.children.find(c => c.id === 'macsteam-fixes');
    const buttons = () => card() ? card().querySelectorAll('button') : [];
    const labels = () => buttons().map(b => b.children[0].textContent).sort();
    const focus = () => events.focus.forEach(fn => fn());
    return { sent, answer, buttons, labels, focus };
}
const oneFix = flags => ({ gameInstalled: true, manifestInstalled: false,
    fixes: [{ id: 'f1', title: 'Online fix', hasFix: true, hasManifest: false, ...flags }] });

(async () => {
    const p = page();
    await p.answer('fixes', oneFix({ applied: false }));
    assert.deepEqual(p.labels(), ['Install fix'], 'not applied: Install only');
    p.focus(); await p.answer('fixes', oneFix({ applied: true, drifted: false }));
    assert.deepEqual(p.labels(), ['Undo fix'], 'applied: Undo only');
    p.focus(); await p.answer('fixes', oneFix({ applied: true, drifted: true }));
    assert.deepEqual(p.labels(), ['Reinstall fix', 'Remove fix'], 'files overwritten by a game update: Reinstall and Remove');
    p.focus(); await p.answer('fixes', oneFix({ applied: false }));
    assert.deepEqual(p.labels(), ['Install fix'], 'Undo disappears once the fix is gone (game deleted)');

    // Install blocked by macOS: the reply carries the pane to open.
    const installing = p.buttons()[0].listeners.click();
    assert.equal(p.sent.at(-1).action, 'fix-install');
    await p.answer('fix-install', { error: 'macOS is blocking macSteam', permission: 'Privacy_AllFiles', permissionTitle: 'Full Disk Access' });
    await installing; await flush();
    assert.ok(p.labels().includes('Open Full Disk Access'), 'offers the privacy pane');
    p.buttons().find(b => b.children[0].textContent === 'Open Full Disk Access').listeners.click();
    assert.deepEqual([p.sent.at(-1).action, p.sent.at(-1).fixID], ['fix-permissions', 'Privacy_AllFiles']);
    console.log('Store fixes UI: passed (install / undo / reinstall-remove states, stale Undo gone, privacy button)');
    process.exit(0);   // unanswered bridge requests keep timers alive
})().catch(error => { console.error(error); process.exit(1); });

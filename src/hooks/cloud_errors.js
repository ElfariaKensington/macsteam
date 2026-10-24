// Runs in JavaScriptCore against a shipped Steam bundle, never against Steam state.
// Match semantic properties; local names, enum aliases and CSS hashes may change.
(function (source) {
    'use strict';
    let text = source;
    const edits = [];
    const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const requireMatch = (re, value, description) => {
        const result = re.exec(value);
        if (!result) throw Error('Unrecognized Steam bundle: ' + description);
        return result;
    };
    // Balanced scanner for the small render functions/methods selected by anchors.
    function closing(start) {
        let depth = 0, quote = '', lineComment = false, blockComment = false;
        for (let i = start; i < text.length; i++) {
            const c = text[i], n = text[i + 1];
            if (lineComment) { if (c === '\n') lineComment = false; continue; }
            if (blockComment) { if (c === '*' && n === '/') { blockComment = false; i++; } continue; }
            if (quote) { if (c === '\\') i++; else if (c === quote) quote = ''; continue; }
            if (c === '/' && n === '/') { lineComment = true; i++; continue; }
            if (c === '/' && n === '*') { blockComment = true; i++; continue; }
            if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
            if (c === '{') depth++;
            if (c === '}' && --depth === 0) return i;
        }
        throw Error('Unbalanced Steam function');
    }
    function enclosing(anchor) {
        const position = text.indexOf(anchor);
        if (position < 0 || text.indexOf(anchor, position + 1) >= 0)
            throw Error('Missing or ambiguous anchor: ' + anchor);
        const re = /function\s*([\w$]*)\s*\(([^)]*)\)\s*\{/g;
        let m, found;
        const candidates = [];
        while ((m = re.exec(text)) && m.index < position)
            candidates.push({start:m.index, open:re.lastIndex - 1, args:m[2].split(',')});
        for (const candidate of candidates.reverse()) {
            try {
                const end = closing(candidate.open);
                if (end > position) { found = {...candidate, end}; break; }
            } catch (_) { /* An unrelated enclosing module may use unsupported syntax. */ }
        }
        if (!found) throw Error('No render function for ' + anchor);
        found.body = text.slice(found.open + 1, found.end);
        return found;
    }
    function insert(pos, value) { edits.push({start:pos, end:pos, value}); }
    function replace(start, end, value) { edits.push({start, end, value}); }
    function errorCondition(fn, flag) {
        const status = requireMatch(/([\w$]+)\s*=\s*([\w$.]+\.eCloudStatus)/, fn.body, 'Cloud status accessor');
        const condition = requireMatch(new RegExp('(?<![\\w$])' + escape(flag) + '=([^;,]+)'), fn.body, 'Cloud error condition')[1];
        if (!condition.includes(status[1]) || !/==/.test(condition) || /[{}]/.test(condition))
            throw Error('Unexpected Cloud condition');
        return condition.replace(new RegExp('(?<![\\w$])' + escape(status[1]) + '(?![\\w$])', 'g'), status[2]);
    }

    const cloud = enclosing('.CloudStatusSyncFail)');
    const flag = requireMatch(/return\s+([\w$]+)\?/, cloud.body, 'Cloud failure branch')[1];
    const condition = errorCondition(cloud, flag);
    const wrapper = enclosing('.PlayBarCloudStatusContainer,');
    const wrapperCondition = condition.replace(new RegExp('(?<![\\w$])' + escape(cloud.args[0]) + '(?![\\w$])', 'g'), wrapper.args[0]);
    // Remove the wrapper AND its invisible width placeholders only on errors.
    insert(wrapper.open + 1, 'if(' + wrapperCondition + ')return null;');

    const gamepad = enclosing('.CloudSyncProblem,');
    const gamepadFlag = requireMatch(/([\w$]+)&&[\w$]+\(\)\.CloudSyncProblem/, gamepad.body, 'gamepad Cloud flag')[1];
    errorCondition(gamepad, gamepadFlag); // Require a real error-derived flag.
    const render = gamepad.body.lastIndexOf('return', gamepad.body.indexOf('.CloudSyncProblem'));
    if (render < 0) throw Error('Missing gamepad render');
    insert(gamepad.open + 1 + render, 'if(' + gamepadFlag + ')return null;');

    // Cloud failure colors are a separate switch from the badge/status label.
    const colors = /case\s+([\w$.]+):return\s+[\w$]+\(\)\.(CloudError|CloudOutOfDate);/g;
    const states = [];
    let m;
    while ((m = colors.exec(text))) {
        states.push(m[1]);
        replace(m.index, colors.lastIndex, ''); // Fall through to installed/local/remote color.
    }
    if (states.length !== 2) throw Error('Unrecognized sidebar Cloud colors');
    const cases = states.map(s => 'case\\s+' + escape(s) + ':').join('');
    const badges = [...text.matchAll(/function\s+[\w$]+\([\w$]+\)\{switch\([^)]*\.display_status\)\{([^}]+)\}return!1\}/g)]
        .filter(match => states.every(state => new RegExp('case\\s+' + escape(state) + ':').test(match[0])));
    if (badges.length !== 1) throw Error('Missing or ambiguous sidebar badge predicate');
    const badge = badges[0];
    let body = badge[0];
    for (const state of states) {
        const re = new RegExp('case\\s+' + escape(state) + ':');
        if (!re.test(body)) throw Error('Cloud badge state mismatch');
        body = body.replace(re, '');
    }
    replace(badge.index, badge.index + badge[0].length, body);
    const label = requireMatch(new RegExp(cases + '([^}]*\\}\\);break)'), text, 'sidebar error status label');
    if (!label[1].includes('appName:') || !label[1].includes('status:')) throw Error('Unexpected sidebar label');
    replace(label.index, label.index + label[0].length, '');

    // Use the existing launch continuation, never resolve saves in either direction.
    const method = requireMatch(/ShowCloudIssueDialog\(([^)]*)\)\{/, text, 'launch Cloud method');
    const open = method.index + method[0].length - 1, end = closing(open);
    const methodBody = text.slice(open + 1, end);
    const issue = requireMatch(/([\w$]+)===['"]syncfailed['"]/, methodBody, 'launch issue argument')[1];
    const callback = requireMatch(/onOK:\(\)=>([\w$]+)\(['"]IgnoreCloud['"]\)/, methodBody, 'play-anyway callback')[1];
    if (!method[1].split(',').includes(issue) || !method[1].split(',').includes(callback)) throw Error('Unexpected callback binding');
    replace(open + 1, end,
        'if(' + issue + '==="cloudconflict"||' + issue + '==="syncfailed")' + callback + '("IgnoreCloud");else if(' +
        issue + '==="pendingcloudsessions")' + callback + '("IgnorePendingCloudSessions");else ' + callback + '(' + issue + ');');

    for (const name of ['Cloud Sync Failure', 'Cloud Sync Conflict']) {
        const anchor = 'strTest:"' + name + '"';
        const pos = text.indexOf(anchor);
        if (pos < 0 || text.indexOf(anchor, pos + 1) >= 0) throw Error('Unknown Cloud notification');
        const start = text.lastIndexOf(']:{', pos) + 2, end = closing(start);
        if (start < 2 || end < pos) throw Error('Unexpected notification record');
        let record = text.slice(start, end + 1);
        if (!/showToast:!0/.test(record) || !/fnTray:[\w$]+/.test(record) || !/sound:[\w$.]+,/.test(record)) throw Error('Unexpected notification settings');
        record = record.replace(/showToast:!0/, 'showToast:!1').replace(/fnTray:[\w$]+/, 'fnTray:null').replace(/sound:[\w$.]+,/, 'playSound:!1,');
        replace(start, end + 1, record);
    }
    edits.sort((a,b) => b.start - a.start);
    let previous = text.length;
    for (const edit of edits) {
        if (edit.end > previous) throw Error('Overlapping Cloud patches');
        text = text.slice(0, edit.start) + edit.value + text.slice(edit.end);
        previous = edit.start;
    }
    if (text.length >= source.length) throw Error('No space for size-preserving patch');
    return text + ' '.repeat(source.length - text.length);
})

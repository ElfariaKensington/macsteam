#!/usr/bin/env python3
"""Regression check: python3 scripts/tests/cloud_errors.py /path/to/vanilla/sp.js"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
original = Path(sys.argv[1]).read_bytes()
source = (repo / 'src/hooks/cloud_errors_legacy.h').read_text()

with tempfile.TemporaryDirectory(prefix='macsteam-cloud-test-') as tmp:
    root = Path(tmp)
    harness = root / 'probe.c'
    harness.write_text('''#include <stdio.h>
int sx_log_level=-1; FILE *sx_log_file;
void sx_clouderrors_patch_installed_js(void);
int main(void) { sx_clouderrors_patch_installed_js(); return 0; }
''')
    binary = root / 'probe'
    include = root / 'cloud_errors_js.inc'
    include.write_text(','.join(str(byte) for byte in (repo / 'src/hooks/cloud_errors.js').read_bytes()))
    subprocess.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Isrc', '-I' + tmp,
                    str(harness), 'src/hooks/hook_clouderrors.c',
                    'src/config/config.c', 'src/util/file.c', '-framework', 'JavaScriptCore', '-o', str(binary)],
                   cwd=repo, check=True)
    target = root / 'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamui/sp.js'
    target.parent.mkdir(parents=True)
    config = root / 'config.yaml'
    env = dict(os.environ, HOME=tmp, MACSTEAM_CONFIG=str(config))

    def run(enabled):
        config.write_text('HideCloudErrors: ' + ('yes' if enabled else 'no') + '\n')
        subprocess.run([str(binary)], env=env, check=True)
        return target.read_bytes()

    target.write_bytes(original)
    assert run(False) == original
    hidden = run(True)
    assert hidden != original and len(hidden) == len(original)
    assert hidden.count(b'\r\n') == original.count(b'\r\n')
    subprocess.run(['node', '--check', str(target)], check=True)
    assert run(True) == hidden
    assert run(False) == original

    # Upgrade from the old child-only hiding, with the setting both on and off.
    legacy_pair = re.search(r'\{ ("(?:[^"\\]|\\.)*"), ("(?:[^"\\]|\\.)*") \}', source)
    old = json.loads(legacy_pair[1]).encode()
    marker = json.loads(legacy_pair[2]).encode().ljust(len(old), b' ')
    assert original.count(old) == 1
    legacy = original
    for a, b in re.findall(r'\{ ("(?:[^"\\]|\\.)*"), ("(?:[^"\\]|\\.)*") \}', source):
        a, b = json.loads(a).encode(), json.loads(b).encode()
        assert legacy.count(a) == 1
        legacy = legacy.replace(a, b.ljust(len(a), b' '))
    for enabled in [True, False]:
        target.write_bytes(legacy)
        assert run(enabled) == (hidden if enabled else original)

    def component(text, start, end):
        begin = text.index(start)
        return text[begin:text.index(end, begin)]

    vanilla = original.decode()
    patched = hidden.decode()
    ze_start = 'function Ze(Bt){return'
    # Other modules use the same minified name: anchor on the Cloud component.
    vanilla_ze = component(vanilla, ze_start + '!Bt.details.bCloudEnabledForApp', 'function de(Bt)')
    patched_ze = component(patched, 'function Ze(Bt){if(Bt.details.eCloudStatus', 'function de(Bt)')
    re_start = 'function re(se){if(se.is_invalid_os_type)'
    re_end = ':v().Uninstalled}'

    def sidebar(text):
        begin = text.index(re_start)
        return text[begin:text.index(re_end, begin) + len(re_end)]

    launch = component(patched, 'ShowCloudIssueDialog(', 'ShowBorrowDialog(').strip()
    data = [vanilla_ze, patched_ze, sidebar(vanilla), sidebar(patched), launch]
    for name in ['Cloud Sync Failure', 'Cloud Sync Conflict']:
        pos = patched.index('strTest:"' + name + '"')
        record = patched[patched.rfind(']:{', 0, pos):pos]
        assert 'fnTray:null' in record and 'showToast:!1' in record and 'playSound:!1' in record
    node = root / 'render-test.js'
    node.write_text('const sources=' + json.dumps(data) + ';\n' + r'''
const assert = require('assert');
const codes = ['in','bp','Kh','Am','os','Wq','b6','A1','hr','hN','c7','js','Gm','Fi'];
const enums = Object.fromEntries(codes.map(k => [k,k]));
const L = {Y_: enums}, D = {Ul: enums};
const e = {jsxs:(type,props)=>({type,props}), jsx:(type,props)=>({type,props})};
const V = ()=>({PlayBarCloudStatusContainer:'cloud'});
const de = 'cloud-child', ht = status => ({placeholder:status});
function cloud(src) { return Function('L','e','V','de','ht','return ('+src+')')(L,e,V,de,ht); }
const before = cloud(sources[0]), after = cloud(sources[1]);
const details = {bCloudEnabledForApp:true,bCloudEnabledForAccount:true,bHasAnyLocalContent:true};
for (const status of ['in','bp','Kh','Am']) {
    const props={details:{...details,eCloudStatus:status}};
    assert(before(props));
    assert.strictEqual(after(props),null,'Cloud wrapper must disappear, including sizing placeholders');
}
for (const status of ['os','Wq','b6','A1']) {
    const props={details:{...details,eCloudStatus:status}};
    assert.deepStrictEqual(after(props),before(props),'Healthy/syncing layout must remain identical');
}
for (const flag of Object.keys(details)) {
    assert.strictEqual(after({details:{...details,[flag]:false,eCloudStatus:'os'}}),null);
}
const classes = new Proxy({}, {get:(_,k)=>k}), v=()=>classes;
const normal = Function('D','v','return ('+sources[2]+')')(D,v);
const fixed = Function('D','v','return ('+sources[3]+')')(D,v);
for (const installed of [false,true]) for (const local of [false,true]) {
    const item={installed,BIsSelectedClientLocal:()=>local};
    for (const status of ['hN','c7']) {
        assert.strictEqual(fixed({...item,display_status:status}),normal({...item,display_status:'hr'}),
                           'Cloud errors must use the normal title color');
    }
    for (const status of ['hr','js','Gm','Fi']) {
        assert.strictEqual(fixed({...item,display_status:status}),normal({...item,display_status:status}));
    }
}
const handler = Function('return ({'+sources[4]+'})')();
for (const [issue, expected] of [['syncfailed','IgnoreCloud'],['cloudconflict','IgnoreCloud'],
                                ['pendingcloudsessions','IgnorePendingCloudSessions'],['unknown','unknown']]) {
    const calls=[];
    handler.ShowCloudIssueDialog(123, issue, ()=>{throw Error('Unexpected cancel');}, value=>calls.push(value));
    assert.deepStrictEqual(calls,[expected]);
}
console.log('PASS: Cloud column collapses; healthy layout unchanged; normal sidebar colors; launch callbacks.');
''')
    subprocess.run(['node', str(node)], check=True)
    # Simulate a Steam rebuild: change local identifiers and CSS hashes. Existing
    # backups from the previous build must never restore over this new version.
    variant = original.decode()
    for before, after in [('Bt','$detailsArg'),('Yt','$cloudState'),('ce','$failureFlag'),('Re','$launchCallback')]:
        variant = re.sub(r'\b' + before + r'\b', after, variant)
    variant = variant.replace('L.Y_.', 'cloudEnums.Y_.').replace('V().', 'cloudStyles().')
    variant = variant.replace('_2cRYms-zZc4misk9tj3bt8', '_newHashDifferentBuild')
    variant = variant.encode()
    target.write_bytes(variant)
    assert run(False) == variant, 'An old backup must never overwrite a Steam update'
    updated = run(True)
    assert updated != variant and len(updated) == len(variant)
    subprocess.run(['node', '--check', str(target)], check=True)
    assert run(False) == variant
    unknown = b'// unsupported future bundle\r\nconst untouched=true;\r\n'
    target.write_bytes(unknown)
    assert run(True) == unknown, 'Unsupported bundles must be left untouched'
    assert run(False) == unknown
    print('PASS: default off, exact size/CRLF, JS syntax, idempotency, restoration, migration, renamed identifiers/hashes, update recovery, unknown bundle untouched.')

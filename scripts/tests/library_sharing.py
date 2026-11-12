#!/usr/bin/env python3
"""Regression check for hiding the shared-library rows against Valve's shipped sp.js.

    python3 scripts/tests/library_sharing.py                    # downloads the live Steam bundle
    python3 scripts/tests/library_sharing.py /path/to/vanilla/sp.js

Fails (non-zero exit) when a Steam update changes the UI so the two rows ("From the library of"
and the legacy-sharing retirement notice) can no longer be found and hidden.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
if len(sys.argv) > 1:
    original = Path(sys.argv[1]).read_bytes()
else:
    import steam_bundle
    print('Steam client build', steam_bundle.build())
    original = Path(steam_bundle.sp_js()).read_bytes()

ROW = re.compile(rb'className:\(0,[\w$]+\.[\w$]+\)\([\w$]+\(\)\.Row,[\w$]+\(\)\.(SharedLibrary|OldSharingWarning)\),')
HIDDEN = b'style:{display:"none"},'


def differing_spans(a, b):
    assert len(a) == len(b)
    spans, start = [], None
    for i in range(len(a)):
        if a[i] != b[i]:
            start = i if start is None else start
            last = i
        elif start is not None and i - last > 64:
            spans.append((start, last + 1)); start = None
    if start is not None:
        spans.append((start, last + 1))
    return spans


with tempfile.TemporaryDirectory(prefix='macsteam-sharing-test-') as tmp:
    root = Path(tmp)
    (root / 'probe.c').write_text('''#include "hooks/hooks.h"
int main(void) { sx_librarysharing_patch_installed_js(); return 0; }
''')
    binary = root / 'probe'
    subprocess.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Isrc', str(root / 'probe.c'),
                    'src/hooks/hook_librarysharing.c', 'src/util/file.c', 'src/util/log.c',
                    '-o', str(binary)], cwd=repo, check=True)
    target = root / 'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamui/sp.js'
    target.parent.mkdir(parents=True)
    env = dict(os.environ, HOME=tmp)

    def run(data):
        target.write_bytes(data)
        subprocess.run([str(binary)], env=env, check=True, stderr=subprocess.DEVNULL)
        return target.read_bytes()

    # 1. The real bundle: exactly the two rows are hidden, in place, without changing the size.
    rows = [(m.start(), m.end(), m.group(1)) for m in ROW.finditer(original)]
    assert sorted(r[2] for r in rows) == [b'OldSharingWarning', b'SharedLibrary'], \
        'Steam changed the shared-library rows; update src/hooks/hook_librarysharing.c: %r' % rows
    patched = run(original)
    assert len(patched) == len(original), 'patch must preserve the file size (Steam verifies it)'
    spans = differing_spans(original, patched)
    assert [(s, e) for s, e, _ in rows] == [(s, e) for s, e in spans], 'only the two rows may change'
    for start, end, _ in rows:
        assert patched[start:end].startswith(HIDDEN) and patched[start + len(HIDDEN):end].strip(b' ') == b''
    subprocess.run(['node', '--check', str(target)], check=True)
    assert run(patched) == patched, 'a second launch must change nothing'

    # 2. Identifier renames in a future build do not matter.
    synthetic = (b'x=(0,e.jsx)(E.Z,{className:(0,Qq.Zz)(Aa$().Row,Aa$().SharedLibrary),children:1});'
                 b'y=(0,e.jsx)(E.Z,{className:(0,a.b)(c().Row,c().OldSharingWarning),children:2});')
    out = run(synthetic)
    assert len(out) == len(synthetic) and out.count(HIDDEN) == 2 and b'SharedLibrary' not in out

    # 3. A bundle without the rows is left alone, never corrupted.
    unknown = b'// future bundle\r\nconst untouched=true;\r\n'
    assert run(unknown) == unknown
    print('PASS: both rows found and hidden in place, size kept, idempotent, renamed identifiers, unknown bundle untouched.')

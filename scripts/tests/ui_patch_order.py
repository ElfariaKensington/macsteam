#!/usr/bin/env python3
"""The sp.js patchers must keep working across launches when they run together.

    python3 scripts/tests/ui_patch_order.py                 # downloads the live Steam bundle
    python3 scripts/tests/ui_patch_order.py /path/to/vanilla/sp.js

Regression for "Cloud errors / shared-library rows stop being hidden after the second launch":
the Cloud patcher keys its recovery copy by the hash of the file it leaves behind, so a patcher
that edits sp.js after it orphans that copy. This runs both patchers in the order loader.c uses,
for several simulated launches, and checks that (1) loader.c still calls them in a safe order,
(2) both patches are applied, (3) later launches change nothing and log no warnings, and
(4) a Steam update (fresh bundle) is patched again.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
if not (repo / 'src/hooks/hook_clouderrors.c').exists():
    # The ordering problem only exists next to the Cloud-error patcher (another branch).
    print('SKIP: no Cloud-error patcher in this tree, so there is no patch order to test')
    sys.exit(0)
if len(sys.argv) > 1:
    original = Path(sys.argv[1]).read_bytes()
else:
    import steam_bundle
    print('Steam client build', steam_bundle.build())
    original = Path(steam_bundle.sp_js()).read_bytes()

# 1. Static order: sharing patch, then cloud patch, in sx_init.
loader = (repo / 'src/core/loader.c').read_text()
init = loader[loader.index('static void sx_init(void)'):]
calls = [m.group(0) for m in re.finditer(r'sx_(librarysharing|clouderrors)_patch_installed_js\(\);', init)]
assert calls == ['sx_librarysharing_patch_installed_js();', 'sx_clouderrors_patch_installed_js();'], \
    'loader.c must patch the shared-library rows before the Cloud errors (found %r)' % calls

with tempfile.TemporaryDirectory(prefix='macsteam-order-test-') as tmp:
    root = Path(tmp)
    (root / 'probe.c').write_text('''#include <stdio.h>
#include "hooks/hooks.h"
int main(void) {
    // Same relative order as sx_init (checked statically above).
    sx_librarysharing_patch_installed_js();
    sx_clouderrors_patch_installed_js();
    return 0;
}
''')
    (root / 'cloud_errors_js.inc').write_text(','.join(str(b) for b in (repo / 'src/hooks/cloud_errors.js').read_bytes()))
    binary = root / 'probe'
    subprocess.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Isrc', '-I' + tmp, str(root / 'probe.c'),
                    'src/hooks/hook_librarysharing.c', 'src/hooks/hook_clouderrors.c',
                    'src/config/config.c', 'src/util/file.c', 'src/util/log.c',
                    '-framework', 'JavaScriptCore', '-o', str(binary)], cwd=repo, check=True)
    target = root / 'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamui/sp.js'
    target.parent.mkdir(parents=True)
    config = root / 'config.yaml'
    config.write_text('HideCloudErrors: yes\n')
    env = dict(os.environ, HOME=tmp, MACSTEAM_CONFIG=str(config), MACSTEAM_LOG_LEVEL='1')

    def launch():
        result = subprocess.run([str(binary)], env=env, capture_output=True, text=True, check=True)
        log = result.stdout + result.stderr
        log_file = root / 'Library/Application Support/macsteam/macsteam.log'
        if log_file.exists():
            log += log_file.read_text()
        return target.read_bytes(), log

    target.write_bytes(original)
    first, log1 = launch()
    assert first != original and len(first) == len(original)
    assert 'hid 2 UI row' in log1, 'shared-library rows were not hidden:\n' + log1
    assert 'Cloud error display: hidden' in log1, 'Cloud errors were not hidden:\n' + log1
    assert b'style:{display:"none"},' in first
    previous_log = log1
    for launch_number in (2, 3):
        again, log = launch()
        new_log = log[len(previous_log):] if log.startswith(previous_log) else log
        previous_log = log
        assert again == first, 'launch %d changed an already-patched sp.js' % launch_number
        assert 'skipped bundle' not in new_log and 'WRN' not in new_log and 'could not' not in new_log, \
            'launch %d logged a problem:\n%s' % (launch_number, new_log)
    subprocess.run(['node', '--check', str(target)], check=True)

    # A Steam update replaces the bundle with a fresh one: it must be patched again.
    target.write_bytes(original)
    updated, _ = launch()
    assert updated == first, 'a fresh Steam bundle must be patched identically'
    print('PASS: sharing rows + Cloud errors patched in order, stable on later launches, re-applied after a Steam update.')

#!/usr/bin/env python3
"""Does macSteam still work with the Steam client Valve ships today?

    python3 scripts/tests/steam_compat.py

Downloads Valve's current macOS client (cached) and runs every in-Steam patch check that applies
to this tree against it: signature DB, Cloud-error patch, shared-library rows, patch order across
launches and the Store page cards. Exits non-zero if any fails, so CI fails the build when a Steam
update breaks something.

A check runs when the feature it covers is in the tree; if the feature is there but its test
file is missing the run fails (so a test can't be dropped silently). Needs python3, node and clang
(Xcode command line tools) on macOS, and network access to Valve's CDN.
"""
from pathlib import Path
import subprocess
import sys
import time

repo = Path(__file__).resolve().parents[2]
here = Path(__file__).resolve().parent
sys.path.insert(0, str(here))
import steam_bundle  # noqa: E402

py = [sys.executable, '-I']
# (name, command, files that must exist for the check to apply, (file, text) that must match)
CHECKS = [
    ('Signature DB vs steamclient.dylib', py + [str(here / 'signatures.py')],
     ['signatures/macos.arm64'], None),
    ('Cloud error patch', py + [str(here / 'cloud_errors.py')],
     ['src/hooks/hook_clouderrors.c'], None),
    ('Shared-library rows patch', py + [str(here / 'library_sharing.py')],
     ['src/hooks/hook_librarysharing.c'], None),
    ('sp.js patch order across launches', py + [str(here / 'ui_patch_order.py')],
     ['src/hooks/hook_clouderrors.c', 'src/hooks/hook_librarysharing.c'], None),
    ('Store Add/Install card UI', ['node', str(here / 'hubcap_store_ui.cjs')],
     ['macsteam-app/Sources/MacsteamApp/Resources/hubcap-store.js'], None),
    ('Store game-fixes card UI', ['node', str(here / 'store_fixes_ui.cjs')],
     ['macsteam-app/Sources/MacsteamApp/Resources/hubcap-store.js'],
     ('macsteam-app/Sources/MacsteamApp/Resources/hubcap-store.js', 'macsteam-fixes')),
]

build = steam_bundle.build()
print('Valve Steam client build:', build, flush=True)
steam_bundle.sp_js()
steam_bundle.steamclient()

failed, ran = [], 0
for name, command, needs, contains in CHECKS:
    if not all((repo / n).exists() for n in needs):
        print('--- %s: not in this tree, skipped' % name, flush=True)
        continue
    if contains and contains[1] not in (repo / contains[0]).read_text():
        print('--- %s: not in this tree, skipped' % name, flush=True)
        continue
    if not Path(command[-1]).exists():
        failed.append(name + ' (test file missing)')
        print('::error::missing test ' + command[-1], flush=True)
        continue
    print('\n=== ' + name, flush=True)
    start = time.time()
    result = subprocess.run(command, cwd=repo)
    ran += 1
    print('--- %s: %s (%.0fs)' % (name, 'ok' if result.returncode == 0 else 'FAILED', time.time() - start), flush=True)
    if result.returncode != 0:
        failed.append(name)
        print('::error title=Steam compatibility::%s failed against Steam build %s' % (name, build), flush=True)

print()
if failed:
    print('Steam compatibility FAILED: ' + '; '.join(failed))
    sys.exit(1)
print('Steam compatibility OK: %d check(s) passed against Steam build %s' % (ran, build))

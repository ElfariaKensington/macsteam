#!/usr/bin/env python3
"""Regression check for the in-memory Steam UI patches against Valve's shipped steamui.

    python3 scripts/tests/steamui_patches.py                # downloads the live Steam bundle
    python3 scripts/tests/steamui_patches.py /path/to/steamui

The patches are served by hook_steamui.c inside Steam Helper; nothing is written to Steam's
files. This builds that code outside Steam and checks, against the given bundle:
  1. every CSS-module key the hide rules use resolves to exactly one class that sp.css styles
     (shared-library owner row, legacy sharing notice, What's New shelf);
  2. cloud_errors.js still recognizes sp.js and its output is valid JavaScript;
  3. end to end, a process named "Steam Helper" with the patch library inserted reads patched
     sp.js and sp.css through open() and fopen(), a library inserted after it (as NotProton is)
     still receives the patched bytes, other processes get the original files, and the files on
     disk are never modified.
Fails (non-zero exit) when a Steam update moves anything these patches depend on.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
if len(sys.argv) > 1:
    steamui = Path(sys.argv[1])
else:
    import steam_bundle
    print('Steam client build', steam_bundle.build())
    steamui = Path(steam_bundle.steamui())

KEYS = ['SharedLibrary', 'OldSharingWarning', 'LibraryHomeWhatsNew', 'UpdatesContainer']
SRC = ['src/hooks/hook_steamui.c', 'src/hooks/steamui_css.c', 'src/hooks/steamui_cloud.c',
       'src/config/config.c', 'src/util/log.c', 'src/util/file.c']
CFLAGS = ['clang', '-std=c17', '-O1', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror',
          '-I' + str(repo / 'src')]

failures = []


def check(ok, message):
    print(('ok   ' if ok else 'FAIL ') + message, flush=True)
    if not ok:
        failures.append(message)


with tempfile.TemporaryDirectory(prefix='macsteam-steamui-test-') as tmp:
    root = Path(tmp)
    inc = root / 'cloud_errors_js.inc'
    inc.write_bytes(subprocess.run(['xxd', '-i'], input=(repo / 'src/hooks/cloud_errors.js').read_bytes(),
                                   stdout=subprocess.PIPE, check=True).stdout)

    # 1 + 2: the pure transforms.
    harness = root / 'harness.c'
    harness.write_text(r'''#include "hooks/steamui.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static char *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)l + 1); *n = fread(b, 1, (size_t)l, f); b[*n] = 0; fclose(f); return b;
}
int main(int argc, char **argv) {
    size_t jl, cl, ol, hl;
    char *js = slurp(argv[1], &jl), *css = slurp(argv[2], &cl);
    if (!js || !css) return 2;
    const char *keys[] = {"SharedLibrary", "OldSharingWarning", "LibraryHomeWhatsNew", "UpdatesContainer"};
    char hashes[4][64];
    sx_steamui_resolve_keys(js, jl, keys, 4, hashes);
    const char *ptrs[4];
    for (int i = 0; i < 4; i++) { printf("key %s %s\n", keys[i], hashes[i]); ptrs[i] = hashes[i]; }
    for (int i = 0; i < 4; i++) {
        char *one = hashes[i][0] ? sx_steamui_css_hide(css, cl, &ptrs[i], 1, &hl) : NULL;
        printf("styled %s %d\n", keys[i], one != NULL);
        free(one);
    }
    char *all = sx_steamui_css_hide(css, cl, ptrs, 4, &hl);
    printf("idempotent %d\n", all && sx_steamui_css_hide(all, hl, ptrs, 4, &ol) == NULL);
    char *out = sx_steamui_cloud_transform(js, jl, &ol);
    printf("cloud %d\n", out != NULL && ol > 0);
    if (out) { FILE *f = fopen(argv[3], "wb"); fwrite(out, 1, ol, f); fclose(f); }
    return 0;
}
''')
    probe = root / 'harness'
    subprocess.run(CFLAGS + ['-I' + tmp, '-framework', 'JavaScriptCore', '-o', str(probe), str(harness),
                             *(str(repo / s) for s in SRC if 'hook_steamui' not in s)], check=True)
    cloud_out = root / 'cloud.js'
    env = dict(os.environ, HOME=str(root / 'home'))
    lines = subprocess.run([str(probe), str(steamui / 'sp.js'), str(steamui / 'css/sp.css'), str(cloud_out)],
                           env=env, stdout=subprocess.PIPE, text=True, check=True).stdout.splitlines()
    result = {}
    for line in lines:
        parts = line.split()
        result[(parts[0], parts[1]) if len(parts) == 3 else parts[0]] = parts[-1]
    for key in KEYS:
        check(bool(result.get(('key', key))) and result.get(('key', key)) != 'key',
              'CSS key %s resolves to one class (%s)' % (key, result.get(('key', key), '?')))
        check(result.get(('styled', key)) == '1', 'sp.css styles the %s class' % key)
    check(result.get('idempotent') == '1', 'hide rule is appended once and only once')
    check(result.get('cloud') == '1', 'cloud_errors.js recognizes sp.js')
    if cloud_out.exists():
        node = shutil.which('node')
        if node:
            parsed = subprocess.run([node, '-e', 'new Function(require("fs").readFileSync(process.argv[1],"utf8"))',
                                     str(cloud_out)], capture_output=True, text=True)
            check(parsed.returncode == 0, 'Cloud-patched sp.js parses' + (': ' + parsed.stderr[-300:] if parsed.returncode else ''))
        text = cloud_out.read_text(errors='replace')
        check('"IgnorePendingCloudSessions");else' in text, 'launch dialog continues without asking')

    # 3: end to end through the interposers, with a library inserted after macsteam's.
    lib = root / 'steamui_test.dylib'
    subprocess.run(CFLAGS + ['-I' + tmp, '-dynamiclib', '-framework', 'JavaScriptCore', '-o', str(lib),
                             *(str(repo / s) for s in SRC)], check=True)
    outer_c = root / 'outer.c'
    outer_c.write_text(r'''#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
/* Stands in for NotProton: wraps open() and appends a marker to steamui .js files it reads
   through the chained open(), the way NotProton's webpatch serves sp.js. */
static int outer_open(const char *p, int f, ...) {
    int fd = open(p, f, 0);
    if (fd < 0 || !p || !strstr(p, "/steamui/") || strcmp(p + strlen(p) - 3, ".js")) return fd;
    size_t cap = 64u << 20, n = 0; char *b = malloc(cap); ssize_t r;
    while ((r = read(fd, b + n, cap - n)) > 0) n += (size_t)r;
    close(fd);
    char t[] = "/tmp/outerXXXXXX"; int o = mkstemp(t); unlink(t);
    write(o, b, n); write(o, "/*outer*/", 9); lseek(o, 0, SEEK_SET); free(b); return o;
}
__attribute__((used)) static struct { const void *a, *b; } ip __attribute__((section("__DATA,__interpose"))) =
    { (const void *)outer_open, (const void *)open };
''')
    outer = root / 'outer.dylib'
    subprocess.run(['clang', '-dynamiclib', '-o', str(outer), str(outer_c)], check=True)
    reader_c = root / 'reader.c'
    reader_c.write_text(r'''#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static void copy(const char *in, const char *out, int use_fopen) {
    size_t cap = 64u << 20, n = 0; char *b = malloc(cap);
    if (use_fopen) { FILE *f = fopen(in, "r"); if (f) { n = fread(b, 1, cap, f); fclose(f); } }
    else { int fd = open(in, O_RDONLY | O_CLOEXEC); ssize_t r; while (fd >= 0 && (r = read(fd, b + n, cap - n)) > 0) n += (size_t)r; if (fd >= 0) close(fd); }
    FILE *o = fopen(out, "wb"); fwrite(b, 1, n, o); fclose(o); free(b);
}
int main(int argc, char **argv) { copy(argv[1], argv[2], 0); copy(argv[3], argv[4], 1); return 0; }
''')
    ui = root / 'Steam.AppBundle/steamui'
    (ui / 'css').mkdir(parents=True)
    shutil.copyfile(steamui / 'sp.js', ui / 'sp.js')
    shutil.copyfile(steamui / 'css/sp.css', ui / 'css/sp.css')
    support = root / 'home/Library/Application Support/macsteam'
    support.mkdir(parents=True, exist_ok=True)
    (support / 'config.yaml').write_text('HideWhatsNew: yes\nHideCloudErrors: yes\n')
    original_js, original_css = (ui / 'sp.js').read_bytes(), (ui / 'css/sp.css').read_bytes()
    for name in ('Steam Helper', 'Steam Helper GPU'):
        exe = root / name
        subprocess.run(['clang', '-o', str(exe), str(reader_c)], check=True)
        js_out, css_out = root / (name + '.js'), root / (name + '.css')
        subprocess.run([str(exe), str(ui / 'sp.js'), str(js_out), str(ui / 'css/sp.css'), str(css_out)],
                       env=dict(env, DYLD_INSERT_LIBRARIES='%s:%s' % (lib, outer)), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        js, css = js_out.read_bytes(), css_out.read_bytes()
        if name == 'Steam Helper':
            check(js.endswith(b'/*outer*/') and js[:-9] == cloud_out.read_bytes() if cloud_out.exists() else False,
                  'Steam Helper: sp.js is Cloud-patched and the outer library still sees the patch')
            check(b'/* macsteam */' in css and css.startswith(original_css), 'Steam Helper: sp.css gets the hide rule')
        else:
            check(js == original_js + b'/*outer*/' and css == original_css,
                  'other processes get the original files')
    check((ui / 'sp.js').read_bytes() == original_js and (ui / 'css/sp.css').read_bytes() == original_css,
          'files on disk are untouched')

if failures:
    print('\n%d check(s) failed: a Steam update moved something the UI patches rely on.' % len(failures))
    sys.exit(1)
print('\nSteam UI patches OK')

#!/usr/bin/env python3
"""Check the newest signature DB against Valve's shipped steamclient.dylib (arm64).

    python3 scripts/tests/signatures.py                      # downloads the live Steam client
    python3 scripts/tests/signatures.py /path/to/steamclient.dylib [--db signatures/macos.arm64/N.json]

Fails (non-zero exit) when a Steam update breaks macSteam's hooks:
  * an AOB no longer matches exactly once in __TEXT,
  * when the DB is for this build, an AOB no longer lands on the recorded function,
  * a `string` / `nth_ref` fallback anchor no longer reaches the same function as the AOB.
A newer Steam build than the DB is only a warning as long as everything above still holds.
"""
import bisect, glob, json, os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")


class Macho:
    def __init__(s, path):
        s.d = open(path, "rb").read()
        assert struct.unpack_from("<I", s.d, 0)[0] == 0xFEEDFACF, "not a thin 64-bit Mach-O"
        s.segs, s.fs_off, s.fs_size, off = [], 0, 0, 32
        for _ in range(struct.unpack_from("<I", s.d, 16)[0]):
            cmd, size = struct.unpack_from("<II", s.d, off)
            if cmd == 0x19:
                s.segs.append((s.d[off + 8:off + 24].split(b"\0")[0].decode(),) + struct.unpack_from("<QQQQ", s.d, off + 24))
            elif cmd == 0x26:
                s.fs_off, s.fs_size = struct.unpack_from("<II", s.d, off + 8)
            off += size
        t = next(x for x in s.segs if x[0] == "__TEXT")
        s.text_vm, s.text_size, s.text_fo = t[1], t[2], t[3]
        starts, p, a = [], s.fs_off, s.text_vm
        while p < s.fs_off + s.fs_size:
            v = sh = 0
            while True:
                b = s.d[p]; p += 1
                v |= (b & 0x7F) << sh; sh += 7
                if not b & 0x80:
                    break
            if v == 0:
                break
            a += v; starts.append(a)
        s.starts = starts

    def scan(s, pat):
        rx = b"".join(re.escape(bytes([b])) if b is not None else b"." for b in pat)
        text = s.d[s.text_fo:s.text_fo + s.text_size]
        return [s.text_vm + m.start() for m in re.finditer(b"(?s)" + rx, text)]

    def function_of(s, va):
        k = bisect.bisect_right(s.starts, va) - 1
        return s.starts[k] if k >= 0 else None

    def pc_refs(s):
        t = s.d[s.text_fo:s.text_fo + s.text_size]
        n = len(t) // 4
        w = struct.unpack("<%dI" % n, t)
        out = []
        for i in range(n - 1):
            x = w[i]
            if x & 0x9F000000 == 0x90000000:
                y = w[i + 1]
                if y & 0xFFC00000 == 0x91000000 and (y >> 5) & 31 == x & 31:
                    imm = (((x >> 5) & 0x7FFFF) << 2) | ((x >> 29) & 3)
                    if imm & 0x100000:
                        imm -= 0x200000
                    pc = s.text_vm + i * 4
                    out.append((pc, (pc & ~0xFFF) + (imm << 12) + ((y >> 10) & 0xFFF)))
        return out

    def string_vas(s, text):
        b, res, i = text.encode() + b"\0", set(), 0
        while True:
            i = s.d.find(b, i)
            if i < 0:
                return res
            if i == 0 or s.d[i - 1] == 0:
                res.update(vm + i - fo for _, vm, vs, fo, fs in s.segs if fo <= i < fo + fs)
            i += 1


def newest_db():
    best = None
    for p in glob.glob(os.path.join(REPO, "signatures", "macos.arm64", "*.json")):
        n = os.path.basename(p)[:-5]
        if n.isdigit() and (best is None or int(n) > best[0]):
            best = (int(n), p)
    return best[1]


def main():
    args = sys.argv[1:]
    db_path = None
    if "--db" in args:
        i = args.index("--db"); db_path = args[i + 1]; del args[i:i + 2]
    live = None
    if args:
        lib = args[0]
    else:
        import steam_bundle
        live = steam_bundle.build()
        lib = steam_bundle.steamclient()
        print("Steam client build", live)
    db = json.load(open(db_path or newest_db()))
    m = Macho(lib)
    same_build = live is None or live == db["steam_build"]
    if not same_build:
        print("WARNING: live Steam is build %s, signature DB is for %s; checking that it still applies"
              % (live, db["steam_build"]))
    failures, refs = [], None
    for s in db["signatures"]:
        name = s["name"]
        pat = [None if t == "??" else int(t, 16) for t in s["aob_hex"].split()]
        hits = m.scan(pat)
        if len(hits) != 1:
            failures.append("%s: AOB matches %d times (needs exactly 1)" % (name, len(hits)))
            continue
        found = hits[0] - (s.get("match_offset") or 0)
        if same_build and "func_addr_this_build" in s and found != int(s["func_addr_this_build"], 16):
            failures.append("%s: AOB resolves to %#x, DB says %s" % (name, found, s["func_addr_this_build"]))
        anchor = s.get("anchor")
        if anchor and anchor["kind"] in ("string", "nth_ref") and "func_addr_this_build" in s:
            refs = refs or m.pc_refs()
            vas = m.string_vas(anchor["value"])
            at = [pc for pc, t in refs if t in vas]
            n = 1 if anchor["kind"] == "string" else anchor.get("n", 1)
            got = m.function_of(at[n - 1]) if len(at) >= n else None
            if anchor["kind"] == "nth_ref" and got != m.function_of(found):
                failures.append("%s: fallback anchor %r #%d reaches %s, AOB reaches %#x (stale n?)"
                                % (name, anchor["value"], n, hex(got) if got else "nothing", m.function_of(found)))
    print("%d signatures checked, %d problem(s)" % (len(db["signatures"]), len(failures)))
    for f in failures:
        print("  FAIL", f)
    if failures:
        sys.exit("Steam update broke macSteam's signatures: regenerate the DB (see scripts/ or port_signatures.py)")
    print("PASS: every AOB unique%s, fallback anchors consistent." % (" and on its recorded function" if same_build else ""))


if __name__ == "__main__":
    main()

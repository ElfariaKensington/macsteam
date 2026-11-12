#!/usr/bin/env python3
"""Fetch Valve's pristine Steam macOS client files for the compatibility tests.

    steam_bundle.py sp-js          # prints the path of the pristine steamui/sp.js
    steam_bundle.py steamclient    # prints the path of the arm64 steamclient.dylib
    steam_bundle.py build          # prints the live client build number

Files come from Valve's CDN (the live steam_client_osx manifest) and are cached under
$MACSTEAM_STEAM_CACHE (default ~/.cache/macsteam-steam/<build>/). Standard library only.
"""
import gzip, io, lzma, os, re, struct, sys, urllib.request, zipfile

CDN = "https://client-update.fastly.steamstatic.com"
CACHE = os.environ.get("MACSTEAM_STEAM_CACHE") or os.path.expanduser("~/.cache/macsteam-steam")


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "macsteam-compat-tests"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                return r.read()
        except Exception:
            if attempt == 2:
                raise


def _vz(d):
    if d[:3] != b"VZa":
        raise ValueError("not a VZ file")
    p = d[7:12]
    size = struct.unpack("<I", d[-6:-2])[0]
    f = {"id": lzma.FILTER_LZMA1, "dict_size": struct.unpack("<I", p[1:5])[0],
         "lc": p[0] % 9, "lp": (p[0] // 9) % 5, "pb": p[0] // 45}
    return lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[f]).decompress(d[12:-10], max_length=size)


def manifest():
    text = _get(CDN + "/steam_client_osx")
    if text[:2] == b"\x1f\x8b":
        text = gzip.decompress(text)
    return text.decode()


def build(text=None):
    return re.search(r'"version"\s+"(\d+)"', text or manifest()).group(1)


def _package(text, name):
    block = re.search(r'"%s"\s*\{(.*?)\}' % re.escape(name), text, re.S)
    if not block:
        raise RuntimeError("manifest has no package " + name)
    return re.search(r'"zipvz"\s+"([^"]+)"', block.group(1)).group(1)


def _cached(name, make):
    text = manifest()
    folder = os.path.join(CACHE, build(text))
    path = os.path.join(folder, name)
    if not os.path.exists(path):
        os.makedirs(folder, exist_ok=True)
        data = make(text)
        tmp = path + ".part"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    return path


def sp_js():
    def make(text):
        z = zipfile.ZipFile(io.BytesIO(_vz(_get(CDN + "/" + _package(text, "steamui_websrc_all")))))
        for entry in z.namelist():
            if entry.replace("\\", "/") == "steamui/sp.js":
                return z.read(entry)
        raise RuntimeError("steamui/sp.js not in package")
    return _cached("sp.js", make)


def steamclient():
    def make(text):
        z = zipfile.ZipFile(io.BytesIO(_vz(_get(CDN + "/" + _package(text, "bins_client_osx")))))
        d = z.read("steamclient.dylib")
        if struct.unpack(">I", d[:4])[0] == 0xCAFEBABE:
            for i in range(struct.unpack(">I", d[4:8])[0]):
                cpu, _, off, size, _ = struct.unpack(">iiIII", d[8 + 20 * i:28 + 20 * i])
                if cpu == 0x0100000C:
                    return d[off:off + size]
            raise RuntimeError("no arm64 slice")
        return d
    return _cached("steamclient.arm64.dylib", make)


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else ""
    if what == "sp-js":
        print(sp_js())
    elif what == "steamclient":
        print(steamclient())
    elif what == "build":
        print(build())
    else:
        sys.exit(__doc__)

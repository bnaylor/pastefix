import json, os, sys, glob
d = os.path.expanduser("~/Library/Application Support/Pastefix/history")
p = os.path.join(d, "index.json")
items = json.load(open(p)) if os.path.exists(p) else []
print(f"items={len(items)} files={sorted(os.listdir(d)) if os.path.isdir(d) else 'nodir'}")
for it in items[:8]:
    t = (it.get("plainText") or "").replace("\n","⏎")[:40]
    print(f"  - text={t!r} rich={bool(it.get('richRTFDFile'))} img={it.get('imageFile') and (it.get('imagePixelWidth'), it.get('imagePixelHeight'))} src={it.get('sourceAppName')} bytes={it.get('byteCount')}")

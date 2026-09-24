import argparse, json, os, subprocess, sys
from datetime import datetime, timezone

HIST_DIR = os.path.expanduser("~/Library/Application Support/Pastefix/history")
INDEX_PATH = os.path.join(HIST_DIR, "index.json")


def load_index():
    return json.load(open(INDEX_PATH)) if os.path.exists(INDEX_PATH) else []


def cmd_list():
    items = load_index()
    print(f"items={len(items)} files={sorted(os.listdir(HIST_DIR)) if os.path.isdir(HIST_DIR) else 'nodir'}")
    for it in items[:8]:
        t = (it.get("plainText") or "").replace("\n", "⏎")[:40]
        print(f"  - text={t!r} rich={bool(it.get('richRTFDFile'))} img={it.get('imageFile') and (it.get('imagePixelWidth'), it.get('imagePixelHeight'))} src={it.get('sourceAppName')} bytes={it.get('byteCount')}")


def pastefix_running():
    try:
        out = subprocess.run(["pgrep", "-f", "MacOS/Pastefix"], capture_output=True, text=True)
        return bool(out.stdout.strip())
    except FileNotFoundError:
        return False


def parse_iso(ts):
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def cmd_purge(contains, after, dry_run):
    # The running app holds the index in memory and overwrites index.json on its own
    # schedule; editing the file out from under it would just get clobbered (or worse,
    # resurrect what we removed) on the next save.
    if pastefix_running():
        print("refusing: a Pastefix process is running (pgrep -f MacOS/Pastefix) — quit it first, the store holds the index in memory")
        sys.exit(1)
    if not contains and not after:
        print("refusing: give --contains and/or --after")
        sys.exit(1)

    after_dt = parse_iso(after) if after else None
    items = load_index()

    def matches(it):
        ok = True
        if contains:
            ok = ok and contains in (it.get("plainText") or "")
        if after_dt:
            ts = it.get("capturedAt")
            if not ts:
                return False
            ok = ok and parse_iso(ts) > after_dt
        return ok

    to_remove = [it for it in items if matches(it)]
    keep = [it for it in items if not matches(it)]

    for it in to_remove:
        text = (it.get("plainText") or "").replace("\n", "⏎")[:40]
        print(f"  - {'would remove' if dry_run else 'removing'} id={it.get('id')} text={text!r} capturedAt={it.get('capturedAt')}")

    if dry_run:
        print(f"dry-run: would remove {len(to_remove)} item(s), keep {len(keep)}")
        return

    for it in to_remove:
        for field in ("richRTFDFile", "imageFile"):
            name = it.get(field)
            if not name:
                continue
            path = os.path.join(HIST_DIR, name)
            if os.path.exists(path):
                os.remove(path)
                print(f"    removed blob {path}")

    tmp_path = INDEX_PATH + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(keep, f)
    os.replace(tmp_path, INDEX_PATH)
    print(f"removed {len(to_remove)} item(s); {len(keep)} remain")


def main():
    parser = argparse.ArgumentParser(prog="idx.py")
    sub = parser.add_subparsers(dest="cmd")
    p_purge = sub.add_parser("purge", help="delete index entries (and their blobs) a test pass created")
    p_purge.add_argument("--contains", help="delete items whose plainText contains this substring")
    p_purge.add_argument("--after", help="delete items captured after this ISO8601 timestamp")
    p_purge.add_argument("--dry-run", action="store_true", help="list matches without deleting")
    args = parser.parse_args()

    if args.cmd == "purge":
        cmd_purge(args.contains, args.after, args.dry_run)
    else:
        cmd_list()


if __name__ == "__main__":
    main()

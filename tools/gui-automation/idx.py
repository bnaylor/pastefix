"""Inspect and purge the Pastefix history store (index.json + blobs).

    python3 idx.py                       list the first entries and the blob directory
    python3 idx.py purge --after TS      remove entries captured after TS (and their blobs)
    python3 idx.py purge --contains STR  remove entries whose plainText contains STR
    ... --dry-run                        list matches, change nothing

PFX_HISTORY_DIR overrides the directory (default: the real store), which is how this
script is tested: against a `cp -R` copy, never the live one.

Purge never removes pinned items, writes index.json.bak-<UTC> (same mode as the index)
before replacing the index, keeps the index's mode (0600 as the app writes it), writes
the new index before deleting blobs, and refuses while a Pastefix process is running
because the app holds the index in memory and would overwrite the edit on its next save.
"""
import argparse, json, os, subprocess, sys
from datetime import datetime, timezone

HIST_DIR = os.environ.get("PFX_HISTORY_DIR") or os.path.expanduser("~/Library/Application Support/Pastefix/history")
INDEX_PATH = os.path.join(HIST_DIR, "index.json")
DEFAULT_MODE = 0o600  # what HistoryStore.writeIndex sets


def load_index():
    if not os.path.exists(INDEX_PATH):
        return []
    with open(INDEX_PATH) as f:
        return json.load(f)


def cmd_list():
    items = load_index()
    print(f"dir={HIST_DIR}")
    print(f"items={len(items)} pinned={sum(1 for it in items if it.get('pinned'))} files={sorted(os.listdir(HIST_DIR)) if os.path.isdir(HIST_DIR) else 'nodir'}")
    for it in items[:8]:
        t = (it.get("plainText") or "").replace("\n", "⏎")[:40]
        print(f"  - text={t!r} rich={bool(it.get('richRTFDFile'))} img={it.get('imageFile') and (it.get('imagePixelWidth'), it.get('imagePixelHeight'))} src={it.get('sourceAppName')} bytes={it.get('byteCount')} pinned={bool(it.get('pinned'))} capturedAt={it.get('capturedAt')}")


def pastefix_running():
    try:
        out = subprocess.run(["pgrep", "-f", "MacOS/Pastefix"], capture_output=True, text=True)
        return bool(out.stdout.strip())
    except FileNotFoundError:
        return False


def parse_item_ts(ts):
    """capturedAt as HistoryStore writes it: JSONEncoder .iso8601, e.g. 2026-09-23T20:33:00Z."""
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    if dt.tzinfo is None:  # the app never writes naive stamps; treat one as UTC rather than guess local
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def parse_after(after):
    """--after from the shell: a naive value is the operator's local time, not UTC."""
    try:
        dt = datetime.fromisoformat(after)
    except ValueError:
        print(f"refusing: --after {after!r} is not ISO-8601 (try $(date -u +%FT%TZ) or 2026-09-23T21:00)")
        sys.exit(1)
    naive = dt.tzinfo is None
    if naive:
        dt = dt.astimezone()  # attach the local zone
    return dt, naive


def index_mode():
    try:
        return os.stat(INDEX_PATH).st_mode & 0o777
    except FileNotFoundError:
        return DEFAULT_MODE


def write_exclusive(path, data, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        os.fchmod(fd, mode)  # umask-proof
        os.write(fd, data)
    finally:
        os.close(fd)


def cmd_purge(contains, after, dry_run):
    # The running app holds the index in memory and overwrites index.json on its own
    # schedule; editing the file out from under it would just get clobbered (or worse,
    # resurrect what we removed) on the next save.
    if pastefix_running():
        print("refusing: a Pastefix process is running (pgrep -f MacOS/Pastefix) — quit it first, the store holds the index in memory")
        sys.exit(1)
    if not contains and not after:
        print("refusing: pass --contains STR and/or --after TS to say what a pass created (add --dry-run to preview)")
        sys.exit(1)

    after_dt = None
    if after:
        after_dt, naive = parse_after(after)
        how = "naive value read as LOCAL time" if naive else "zone given"
        print(f"window: capturedAt > {after_dt.astimezone(timezone.utc).isoformat()} (UTC; {how}, input {after!r})")
    if contains:
        print(f"filter: plainText contains {contains!r}")
    print(f"index: {INDEX_PATH}")

    items = load_index()
    skipped_pinned, skipped_unparsed = [], []

    def matches(it):
        if contains and contains not in (it.get("plainText") or ""):
            return False
        if after_dt is not None:
            ts = parse_item_ts(it.get("capturedAt") or "")
            if ts is None:
                skipped_unparsed.append(it)
                return False
            if not ts > after_dt:
                return False
        if it.get("pinned") is True:
            skipped_pinned.append(it)
            return False
        return True

    to_remove = [it for it in items if matches(it)]
    remove_ids = {it.get("id") for it in to_remove}
    keep = [it for it in items if it.get("id") not in remove_ids]

    for it in skipped_pinned:
        print(f"  skipping pinned id={it.get('id')} capturedAt={it.get('capturedAt')}")
    for it in skipped_unparsed:
        print(f"  skipping id={it.get('id')}: capturedAt={it.get('capturedAt')!r} did not parse")
    for it in to_remove:
        text = (it.get("plainText") or "").replace("\n", "⏎")[:40]
        print(f"  - {'would remove' if dry_run else 'removing'} id={it.get('id')} text={text!r} capturedAt={it.get('capturedAt')}")

    if dry_run:
        print(f"dry-run: would remove {len(to_remove)} item(s), keep {len(keep)} (pinned skipped: {len(skipped_pinned)})")
        return
    if not to_remove:
        print(f"nothing matched; index untouched ({len(keep)} item(s), pinned skipped: {len(skipped_pinned)})")
        return

    mode = index_mode()

    # 1. Backup, same mode, before anything is rewritten.
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    with open(INDEX_PATH, "rb") as f:
        original = f.read()
    for n in range(100):  # a second purge in the same second gets a suffix, never a clobber
        backup_path = f"{INDEX_PATH}.bak-{stamp}" + (f"-{n}" if n else "")
        try:
            write_exclusive(backup_path, original, mode)
            break
        except FileExistsError:
            continue
    else:
        print("refusing: could not create a backup name; index untouched")
        sys.exit(1)
    print(f"backup: {backup_path} (mode {mode:o})")

    # 2. New index: written to a temp file with the original's mode, then renamed over it.
    tmp_path = INDEX_PATH + ".tmp"
    if os.path.exists(tmp_path):
        os.remove(tmp_path)
    write_exclusive(tmp_path, json.dumps(keep).encode(), mode)
    os.replace(tmp_path, INDEX_PATH)
    print(f"index rewritten: {len(to_remove)} removed, {len(keep)} remain (mode {index_mode():o})")

    # 3. Blobs of removed items — only names inside the directory, and only when no kept
    #    item still references the same file.
    still_referenced = {it.get(field) for it in keep for field in ("richRTFDFile", "imageFile") if it.get(field)}
    for it in to_remove:
        for field in ("richRTFDFile", "imageFile"):
            name = it.get(field)
            if not name:
                continue
            if os.path.basename(name) != name:
                print(f"    not touching blob with a path in its name: {name!r}")
                continue
            if name in still_referenced:
                print(f"    keeping blob {name}: a kept item references it")
                continue
            path = os.path.join(HIST_DIR, name)
            if os.path.exists(path):
                os.remove(path)
                print(f"    removed blob {path}")


def main():
    parser = argparse.ArgumentParser(prog="idx.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd")
    p_purge = sub.add_parser("purge", help="delete index entries (and their blobs) a test pass created; pinned items are never removed")
    p_purge.add_argument("--contains", help="delete items whose plainText contains this substring")
    p_purge.add_argument("--after", help="delete items captured after this ISO-8601 timestamp (naive = local time; use $(date -u +%%FT%%TZ) for UTC)")
    p_purge.add_argument("--dry-run", action="store_true", help="list matches without deleting")
    args = parser.parse_args()

    if args.cmd == "purge":
        cmd_purge(args.contains, args.after, args.dry_run)
    else:
        cmd_list()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""brownout-report.py — usage history aggregation for the brownout plugin.

Subcommands:
  compact  --file F --retention-days N --raw-hours H
      Prune samples older than N days; downsample samples older than H hours
      into one hourly aggregate line per unit (flagged "agg":1, weight w=60).
  top      --file F [--json] [--limit N] [--blocklist-regex R]
      Aggregate per-unit stats over 24h and 7d windows:
        cpu_pct_24h      average CPU% over the last 24h
        cpu_min_24h      total CPU-minutes over the last 24h
        batt_cpu_min_7d  CPU-minutes consumed *while on battery*, last 7d
        mem_mb           most recent memory footprint (MB)
      Sorted by batt_cpu_min_7d desc, then cpu_min_24h desc.
      Text output is a table; --json emits {"units":[...]} for the bar popup.

JSONL line schema: {"t":epoch,"u":"unit","c":cpu%,"m":mem_bytes,"b":0|1,"w":minutes,"agg":0|1}
"""

import argparse
import json
import os
import re
import sys
import time


def read_lines(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and "t" in obj and "u" in obj:
                out.append(obj)
    return out


def write_lines(path, lines):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for obj in lines:
            fh.write(json.dumps(obj, separators=(",", ":")) + "\n")
    os.replace(tmp, path)


def unescape_unit(unit):
    """systemd escapes '-' as \\x2d inside some unit names; prettify for display
    (the raw escaped id stays for systemctl calls)."""
    name = re.sub(r"\\x([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), unit)
    if name.endswith(".service"):
        name = name[: -len(".service")]
    return name


def cmd_compact(args):
    now = int(time.time())
    retention_cutoff = now - args.retention_days * 86400
    raw_cutoff = now - args.raw_hours * 3600
    lines = read_lines(args.file)
    kept, buckets = [], {}
    for obj in lines:
        if obj["t"] < retention_cutoff:
            continue
        if obj["t"] >= raw_cutoff or obj.get("agg"):
            # Already-aggregated lines past the raw window stay as-is
            # (they are already hourly); fresh aggregates also pass through.
            if obj["t"] < retention_cutoff:
                continue
            kept.append(obj)
            continue
        # Raw line inside the downsample window -> fold into an hourly bucket.
        hour = obj["t"] - (obj["t"] % 3600)
        key = (obj["u"], hour)
        acc = buckets.setdefault(key, {"c": 0.0, "w": 0.0, "m": 0, "b": 0, "n": 0})
        acc["c"] += float(obj.get("c", 0)) * float(obj.get("w", 1))
        acc["w"] += float(obj.get("w", 1))
        acc["m"] = max(acc["m"], int(obj.get("m", 0)))
        acc["b"] += 1 if obj.get("b") else 0
        acc["n"] += 1
    for (unit, hour), acc in buckets.items():
        if acc["w"] <= 0:
            continue
        kept.append({
            "t": hour,
            "u": unit,
            "c": round(acc["c"] / acc["w"], 2),
            "m": acc["m"],
            "b": 1 if acc["b"] * 2 >= acc["n"] else 0,
            "w": round(acc["w"], 2),
            "agg": 1,
        })
    kept.sort(key=lambda o: o["t"])
    write_lines(args.file, kept)
    return 0


def cmd_top(args):
    now = int(time.time())
    w24 = now - 86400
    w7 = now - 7 * 86400
    block = re.compile(args.blocklist_regex) if args.blocklist_regex else None
    stats = {}
    for obj in read_lines(args.file):
        unit = obj["u"]
        if block and block.match(unit):
            continue
        s = stats.setdefault(unit, {
            "id": unit, "c24": 0.0, "w24": 0.0, "n24": 0,
            "b7": 0.0, "m": 0, "last": 0,
        })
        w = float(obj.get("w", 1))
        c = float(obj.get("c", 0))
        if obj["t"] >= w24:
            s["c24"] += c * w
            s["w24"] += w
            s["n24"] += 1
        if obj["t"] >= w7 and obj.get("b"):
            s["b7"] += c * w / 100.0
        mem = int(obj.get("m", 0))
        if obj["t"] >= s["last"] and mem > 0:
            s["m"] = mem
            s["last"] = obj["t"]

    rows = []
    for s in stats.values():
        if s["w24"] <= 0 and s["b7"] <= 0:
            continue
        rows.append({
            "id": s["id"],
            "name": unescape_unit(s["id"]),
            "cpu_pct_24h": round(s["c24"] / s["w24"], 2) if s["w24"] > 0 else 0.0,
            "cpu_min_24h": round(s["c24"] / 100.0, 1),
            "batt_cpu_min_7d": round(s["b7"], 1),
            "mem_mb": round(s["m"] / 1048576.0, 1),
        })
    rows.sort(key=lambda r: (-r["batt_cpu_min_7d"], -r["cpu_min_24h"]))
    if args.limit > 0:
        rows = rows[: args.limit]

    if args.json:
        json.dump({"units": rows}, sys.stdout)
        print()
    else:
        if not rows:
            print("No usage samples yet (the watcher samples every minute).")
            return 0
        hdr = f"{'unit':<32}{'24h avg%':>10}{'24h cpu-min':>13}{'batt cpu-min/7d':>17}{'mem MB':>9}"
        print(hdr)
        print("-" * len(hdr))
        for r in rows:
            print(f"{r['name']:<32}{r['cpu_pct_24h']:>10.1f}{r['cpu_min_24h']:>13.1f}"
                  f"{r['batt_cpu_min_7d']:>17.1f}{r['mem_mb']:>9.0f}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("compact")
    c.add_argument("--file", required=True)
    c.add_argument("--retention-days", type=int, default=14)
    c.add_argument("--raw-hours", type=int, default=48)
    c.set_defaults(func=cmd_compact)

    t = sub.add_parser("top")
    t.add_argument("--file", required=True)
    t.add_argument("--json", action="store_true")
    t.add_argument("--limit", type=int, default=0)
    t.add_argument("--blocklist-regex", default="")
    t.set_defaults(func=cmd_top)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""下载 RVC 推理所需权重（清单来自官方客户端，内置硬编码）。
用法:
  python3 fetch_weights.py --dest /opt/replay/weights            # 全量(约3.4GB)
  python3 fetch_weights.py --dest /opt/replay/weights --lite     # 仅推理核心+分离模型(约0.5GB)
"""
import argparse, hashlib, json, os, urllib.request

CDN = "https://base-weights.weights.com/"
HERE = os.path.dirname(os.path.abspath(__file__))


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", default="/opt/replay/weights")
    ap.add_argument("--lite", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.dest, exist_ok=True)

    required = json.load(open(os.path.join(HERE, "weights_required.json")))
    stem = json.load(open(os.path.join(HERE, "weights_stem.json")))
    if args.lite:
        required = [w for w in required if not w["name"][0] in ("D", "G")]
    items = required + stem
    print(f"共 {len(items)} 个权重文件，合计 {sum(w['size'] for w in items) / 1e9:.2f} GB", flush=True)

    for i, w in enumerate(items, 1):
        target = os.path.join(args.dest, w["name"])
        if os.path.isfile(target) and os.path.getsize(target) == w["size"]:
            if sha1_of(target) == w["sha1"]:
                print(f"[{i}/{len(items)}] 跳过 {w['name']}", flush=True)
                continue
        for attempt in range(4):
            try:
                print(f"[{i}/{len(items)}] 下载 {w['name']} ({w['size'] / 1e6:.0f}MB)…", flush=True)
                req = urllib.request.Request(CDN + w["name"], headers={"User-Agent": "ReplayCloud-Setup/1.0"})
                with urllib.request.urlopen(req, timeout=180) as r, open(target + ".part", "wb") as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
                if sha1_of(target + ".part") != w["sha1"]:
                    raise RuntimeError("SHA1 校验失败")
                os.replace(target + ".part", target)
                break
            except Exception as e:  # noqa: BLE001
                print(f"  第 {attempt + 1} 次失败: {e}", flush=True)
        else:
            raise SystemExit(f"下载失败: {w['name']}")
    print("权重全部就绪。", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""按官方 manifest 下载 Replay 推理服务端（linux-x64），并校验 SHA1。
用法: python3 download_server.py [--dest /opt/replay/server]
"""
import argparse, concurrent.futures, hashlib, io, json, os, sys, urllib.request, zipfile

CONFIG_URL = "https://replay-servers.weights.com/latest-linux-x64-pyinstaller6.json"
CDN = "https://replay-servers.weights.com/"


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, retries=4):
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ReplayCloud-Setup/1.0"})
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            print(f"  重试 {i + 1}/{retries}: {e}", flush=True)
    raise last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", default="/opt/replay/server")
    args = ap.parse_args()
    dest = args.dest
    os.makedirs(dest, exist_ok=True)

    print("获取服务端配置…", flush=True)
    config = json.loads(fetch(CONFIG_URL))
    print("服务端版本:", config["version"], flush=True)
    manifest = config["manifest"]
    entries = list(manifest.values())
    total = sum(e["zip_size"] for e in entries)
    print(f"共 {len(entries)} 个组件，压缩包合计 {total / 1e9:.2f} GB", flush=True)

    def work(entry):
        rel = entry["path"]
        target = os.path.join(dest, rel)
        if rel == "other.zip":
            # 已实测：此 asset 直接包含全部核心文件（30686 个，含主程序），
            # manifest 的 path 字段仅为标记，不存在 "other.zip" 实体文件。
            if os.path.isfile(os.path.join(dest, "replay-server-linux")):
                return "跳过 other.zip（主程序已存在）"
            data = fetch(CDN + entry["asset_name"])
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                z.extractall(dest)
            if os.path.isfile(os.path.join(dest, "replay-server-linux")):
                return f"完成 other.zip（{entry.get('file_count', '?')} 个文件，含主程序）"
            return "警告 other.zip 解压后未找到 replay-server-linux"
        if os.path.isfile(target):
            try:
                if sha1_of(target) == entry["sha1"]:
                    return f"跳过(已存在) {rel}"
            except OSError:
                pass
        data = fetch(CDN + entry["asset_name"])
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            z.extractall(dest)
        if not os.path.isfile(target):
            # 个别 zip 内目录层级可能不同，尝试在包内查找同名文件
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                names = z.namelist()
                cand = [n for n in names if n.endswith(rel)] or names
                if len(cand) == 1:
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    with open(target, "wb") as f:
                        f.write(z.read(cand[0]))
        if os.path.isfile(target):
            actual = sha1_of(target)
            if actual != entry["sha1"]:
                return f"警告 SHA1 不符 {rel}"
            return f"完成 {rel}"
        return f"警告 未找到 {rel}"

    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        for msg in ex.map(work, entries):
            done += 1
            print(f"[{done}/{len(entries)}] {msg}", flush=True)

    with open(os.path.join(dest, "version.txt"), "w") as f:
        f.write(config["version"])
    bin_path = os.path.join(dest, "replay-server-linux")
    if os.path.isfile(bin_path):
        os.chmod(bin_path, 0o755)
        print("服务端就绪:", bin_path, flush=True)
    else:
        print("错误：未找到 replay-server-linux，请检查上方警告", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

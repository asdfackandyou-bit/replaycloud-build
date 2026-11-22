#!/usr/bin/env python3
"""ReplayCloud 网关：鉴权 + 模型/音频/产物管理 + 反代官方推理服务端。
运行: REPLAY_TOKEN=你的令牌 uvicorn gateway:app --host 0.0.0.0 --port 8080
"""
import os, secrets, shutil, time, uuid, zipfile
from pathlib import Path

import httpx
from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

HOME = Path(os.environ.get("REPLAY_HOME", "/opt/replay"))
MODELS = HOME / "models"
WEIGHTS = HOME / "weights"
OUTPUTS = HOME / "outputs"
UPLOADS = HOME / "uploads"
for d in (MODELS, WEIGHTS, OUTPUTS, UPLOADS):
    d.mkdir(parents=True, exist_ok=True)

UPSTREAM = os.environ.get("REPLAY_UPSTREAM", "http://127.0.0.1:62362")
TOKEN = os.environ.get("REPLAY_TOKEN", "")
if not TOKEN:
    TOKEN = secrets.token_urlsafe(24)
    print(f"[ReplayCloud] 未设置 REPLAY_TOKEN，本次随机令牌: {TOKEN}", flush=True)

app = FastAPI(title="ReplayCloud Gateway")
client = httpx.AsyncClient(base_url=UPSTREAM, timeout=httpx.Timeout(600.0, connect=10.0))


def auth(request: Request):
    if request.method == "OPTIONS":
        return
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    token = token or request.query_params.get("token", "")
    if token != TOKEN:
        raise HTTPException(401, "令牌错误")


@app.middleware("http")
async def guard(request: Request, call_next):
    if request.url.path != "/":
        auth(request)
    return await call_next(request)


@app.get("/")
async def root():
    return {"name": "ReplayCloud Gateway", "ok": True}


async def proxy(method: str, path: str, payload=None):
    try:
        if method == "GET":
            r = await client.get(path)
        else:
            r = await client.post(path, json=payload)
        return JSONResponse(r.json() if r.content else {}, status_code=r.status_code)
    except httpx.HTTPError as e:
        raise HTTPException(502, f"推理服务端未响应: {e}")


@app.get("/health")
async def health():
    return await proxy("GET", "/health")


@app.get("/device_options")
async def device_options():
    return await proxy("GET", "/device_options")


@app.get("/stemming_models")
async def stemming_models():
    return await proxy("GET", "/stemming_models")


@app.get("/jobs")
async def jobs():
    return await proxy("GET", "/jobs")


@app.post("/song_progress")
async def song_progress(body: dict):
    return await proxy("POST", "/song_progress", body)


@app.post("/stop_job")
async def stop_job(body: dict):
    return await proxy("POST", "/stop_job", body)


@app.post("/clear_job")
async def clear_job(body: dict):
    return await proxy("POST", "/clear_job", body)


def model_info(p: Path):
    size = 0
    has_index = False
    if p.is_dir():
        files = [f for f in p.rglob("*") if f.is_file()]
        size = sum(f.stat().st_size for f in files)
        has_index = any(f.suffix == ".index" for f in files)
    else:
        size = p.stat().st_size
    return {
        "id": p.name,
        "name": p.name,
        "hasIndex": has_index,
        "size": size,
        "last_modified": p.stat().st_mtime,
    }


@app.get("/models")
async def list_models():
    items = [p for p in MODELS.iterdir() if not p.name.startswith(".")]
    return {"models": sorted((model_info(p) for p in items), key=lambda m: m["name"].lower())}


@app.post("/upload_model")
async def upload_model(file: UploadFile = File(...)):
    """上传 RVC 模型 zip（含 .pth/.index），自动解压到模型目录。"""
    if not file.filename.lower().endswith(".zip"):
        raise HTTPException(400, "请上传 zip 格式模型包")
    name = Path(file.filename).stem
    dest = MODELS / name
    dest.mkdir(parents=True, exist_ok=True)
    tmp = UPLOADS / f"model-{uuid.uuid4()}.zip"
    with tmp.open("wb") as f:
        shutil.copyfileobj(file.file, f)
    try:
        with zipfile.ZipFile(tmp) as z:
            for member in z.namelist():
                if member.startswith("/") or ".." in member:
                    raise HTTPException(400, "非法压缩包路径")
            z.extractall(dest)
    except zipfile.BadZipFile:
        raise HTTPException(400, "zip 文件损坏")
    finally:
        tmp.unlink(missing_ok=True)
    return {"ok": True, "model": model_info(dest)}


ALLOWED_AUDIO = {".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac", ".aiff", ".opus", ".webm"}


@app.post("/upload_audio")
async def upload_audio(file: UploadFile = File(...)):
    ext = Path(file.filename).suffix.lower() or ".wav"
    if ext not in ALLOWED_AUDIO:
        raise HTTPException(400, f"不支持的音频格式 {ext}")
    dest = UPLOADS / f"{uuid.uuid4()}{ext}"
    with dest.open("wb") as f:
        shutil.copyfileobj(file.file, f)
    return {"ok": True, "path": str(dest), "name": file.filename, "size": dest.stat().st_size}


class CreateSongBody(BaseModel):
    modelId: str
    songUrlOrFilePath: str
    options: dict | None = None


@app.post("/create_song")
async def create_song(body: CreateSongBody):
    if ".." in body.modelId or body.modelId.startswith("/"):
        raise HTTPException(400, "非法模型名")
    if not (MODELS / body.modelId).exists():
        raise HTTPException(404, f"模型不存在: {body.modelId}")
    payload = {
        "outputDirectory": str(OUTPUTS),
        "modelsPath": str(MODELS),
        "weightsPath": str(WEIGHTS),
        "modelData": [{"modelId": body.modelId, "weight": 1}],
        "songUrlOrFilePath": body.songUrlOrFilePath,
        "options": body.options or {},
    }
    return await proxy("POST", "/create_song", payload)


def safe_file(path_str: str) -> Path:
    p = Path(path_str).resolve()
    for root in (OUTPUTS, UPLOADS):
        try:
            p.relative_to(root.resolve())
            if p.is_file():
                return p
        except ValueError:
            continue
    raise HTTPException(403, "只允许访问产物与上传目录内的文件")


@app.get("/file")
async def get_file(path: str):
    return FileResponse(safe_file(path))


@app.get("/songs")
async def list_songs():
    items = []
    for p in sorted(OUTPUTS.rglob("*"), key=lambda x: x.stat().st_mtime if x.exists() else 0, reverse=True):
        if p.is_file() and p.suffix.lower() in ALLOWED_AUDIO:
            items.append({
                "path": str(p),
                "name": p.name,
                "size": p.stat().st_size,
                "modified": p.stat().st_mtime,
            })
    return {"songs": items}


@app.on_event("shutdown")
async def shutdown():
    await client.aclose()

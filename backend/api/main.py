"""
FastAPI RPA – Instagram Automation API
======================================
Main application entry point.
Run with:  uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload
"""

import sys
import os
import base64
import hashlib
import pathlib

# Ensure the project root is on sys.path so all existing modules resolve
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load_encrypted_env() -> None:
    """Decrypt .env.enc (next to this package's parent) into os.environ.

    Runs at import time so env vars are available regardless of whether the
    server was started via run.py, `python start.py`, or plain `uvicorn`.
    Already-set env vars are NOT overwritten.
    """
    SECRET_KEY = "9cbfcce635d1160bf8fd4143a322ef1c1edebc84749ae1d34bcb167347754406"
    # backend/.env.enc lives one level above this file (api/)
    enc_path = pathlib.Path(__file__).resolve().parent.parent / ".env.enc"
    if not enc_path.exists():
        return
    try:
        key = hashlib.sha256(SECRET_KEY.encode()).digest()
        decoded = base64.b64decode(enc_path.read_bytes())
        decrypted = bytes(b ^ key[i % len(key)] for i, b in enumerate(decoded))
        for line in decrypted.decode("utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            var, _, val = line.partition("=")
            # Don't overwrite values already injected by run.py or the OS
            os.environ.setdefault(var.strip(), val.strip())
    except Exception as exc:  # noqa: BLE001
        print(f"[main] WARNING: could not decrypt .env.enc: {exc}")


_load_encrypted_env()

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from api.routers import session, brain, scraper, scrolling, search, leads
from api.shared.models import (
    get_task, list_all_tasks, stop_task, stop_all_tasks,
    TaskStatus, TaskInfo, TaskResponse,
)

app = FastAPI(
    title="Instagram RPA Automation API",
    description=(
        "Production-ready REST API wrapping Playwright-based Instagram automation. "
        "Organised into five modules: **Session**, **Brain (Analysis)**, **Scraper**, "
        "**Scrolling Automation**, and **Search & Explore**."
    ),
    version="1.0.0",
)

# CORS – allow all in dev; tighten for production
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Register Routers ────────────────────────────────────────────────
app.include_router(session.router)
app.include_router(brain.router)
app.include_router(scraper.router)
app.include_router(scrolling.router)
app.include_router(search.router)
app.include_router(leads.router)


# ── Global Task Endpoints ──────────────────────────────────────────
@app.get("/", tags=["Health"])
async def health_check():
    """Health-check / root endpoint."""
    return {"status": "ok", "service": "Instagram RPA API"}


@app.get("/tasks", response_model=list[TaskInfo], tags=["Tasks"])
async def get_all_tasks():
    """List every background task and its current status."""
    return list_all_tasks()


@app.get("/tasks/{task_id}", response_model=TaskInfo, tags=["Tasks"])
async def get_task_status(task_id: str):
    """Get the status, logs and result of a specific task."""
    task = get_task(task_id)
    if not task:
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="Task not found")
    return task


@app.post("/tasks/stop-all", tags=["Tasks"])
async def stop_all_running_tasks():
    """Send a stop signal to ALL running and pending tasks at once."""
    stopped_ids = stop_all_tasks()
    return {
        "stopped_count": len(stopped_ids),
        "stopped_task_ids": stopped_ids,
        "message": f"Stop signal sent to {len(stopped_ids)} task(s)"
            if stopped_ids else "No running tasks to stop",
    }


@app.post("/tasks/{task_id}/stop", response_model=TaskResponse, tags=["Tasks"])
async def stop_running_task(task_id: str):
    """Send a stop signal to a running background task."""
    task = get_task(task_id)
    if not task:
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="Task not found")
    stop_task(task_id)
    return TaskResponse(task_id=task_id, status="stopping", message="Stop signal sent")

"""Web UI routes — login, register, search, settings."""

from fastapi import APIRouter, Depends, Form, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from psycopg.errors import UniqueViolation

import db
from auth import create_jwt, get_current_user_session, SESSION_COOKIE
from config import REGISTRATION_ENABLED
from search import search
from notes import get_all_tags, get_note_by_path

router = APIRouter()
templates = Jinja2Templates(directory="templates")


def _flash_context(request: Request, user=None, **kwargs):
    """Build template context with common fields."""
    ctx = {"request": request, "user": user, "get_flashed_messages": lambda: []}
    ctx.update(kwargs)
    return ctx


# --- Auth routes ---


@router.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    ctx = _flash_context(request, registration_enabled=REGISTRATION_ENABLED)
    return templates.TemplateResponse("login.html", ctx)


@router.post("/login", response_class=HTMLResponse)
def login_submit(request: Request, email: str = Form(...), password: str = Form(...)):
    user = db.authenticate_user(email, password)
    if user is None:
        ctx = _flash_context(request, error="Invalid email or password", registration_enabled=REGISTRATION_ENABLED)
        return templates.TemplateResponse("login.html", ctx, status_code=401)
    token = create_jwt(user["id"])
    response = RedirectResponse("/search", status_code=303)
    response.set_cookie(SESSION_COOKIE, token, httponly=True, samesite="lax", max_age=7 * 86400)
    return response


@router.get("/register", response_class=HTMLResponse)
def register_page(request: Request):
    if not REGISTRATION_ENABLED:
        return RedirectResponse("/login", status_code=303)
    ctx = _flash_context(request)
    return templates.TemplateResponse("register.html", ctx)


@router.post("/register", response_class=HTMLResponse)
def register_submit(
    request: Request,
    display_name: str = Form(...),
    email: str = Form(...),
    password: str = Form(...),
):
    if not REGISTRATION_ENABLED:
        return RedirectResponse("/login", status_code=303)
    try:
        user = db.create_user(email, password, display_name)
    except UniqueViolation:
        ctx = _flash_context(request, error="Email already registered")
        return templates.TemplateResponse("register.html", ctx, status_code=400)
    token = create_jwt(user["id"])
    response = RedirectResponse("/search", status_code=303)
    response.set_cookie(SESSION_COOKIE, token, httponly=True, samesite="lax", max_age=7 * 86400)
    return response


@router.get("/logout")
def logout():
    response = RedirectResponse("/login", status_code=303)
    response.delete_cookie(SESSION_COOKIE)
    return response


# --- Search routes ---


@router.get("/search", response_class=HTMLResponse)
def search_page(request: Request, user: dict = Depends(get_current_user_session)):
    user_id = str(user["id"])
    tags = get_all_tags(user_id=user_id)
    ctx = _flash_context(request, user=user, tags=tags)
    return templates.TemplateResponse("search.html", ctx)


@router.get("/search/results", response_class=HTMLResponse)
def search_results(
    request: Request,
    query: str = Query(...),
    tags: list[str] = Query(default=[]),
    user: dict = Depends(get_current_user_session),
):
    user_id = str(user["id"])
    results = search(query, limit=10, tags=tags or None, user_id=user_id)
    ctx = _flash_context(request, user=user, results=results)
    return templates.TemplateResponse("_results.html", ctx)


# --- Note viewer ---


@router.get("/note/view", response_class=HTMLResponse)
def note_view(
    request: Request,
    source_path: str = Query(...),
    user: dict = Depends(get_current_user_session),
):
    user_id = str(user["id"])
    note = get_note_by_path(source_path, user_id=user_id)
    ctx = _flash_context(request, user=user, note=note)
    return templates.TemplateResponse("_note.html", ctx)


@router.get("/note/close", response_class=HTMLResponse)
def note_close():
    return HTMLResponse("")


# --- Settings ---


@router.get("/settings", response_class=HTMLResponse)
def settings_page(request: Request, user: dict = Depends(get_current_user_session)):
    keys = db.list_api_keys(user["id"])
    ctx = _flash_context(request, user=user, keys=keys)
    return templates.TemplateResponse("settings.html", ctx)


@router.post("/settings/keys", response_class=HTMLResponse)
def create_key(
    request: Request,
    name: str = Form(...),
    user: dict = Depends(get_current_user_session),
):
    new_key = db.create_api_key(user["id"], name)
    keys = db.list_api_keys(user["id"])
    ctx = _flash_context(request, user=user, keys=keys, new_key=new_key)
    return templates.TemplateResponse("settings.html", ctx)


@router.post("/settings/keys/{key_id}/delete")
def delete_key(key_id: int, user: dict = Depends(get_current_user_session)):
    db.delete_api_key(user["id"], key_id)
    return RedirectResponse("/settings", status_code=303)

# Starlette 1.0 TemplateResponse Migration

Last verified: 2026-03-29

## The Problem

Starlette 1.0 changed the `TemplateResponse` signature. The old API still "works" via a deprecation shim, but causes a subtle `TypeError: unhashable type: 'dict'` in Jinja2's LRU cache when the context dict contains a `request` key.

## Old API (Starlette < 1.0)

```python
ctx = {"request": request, "user": user, **kwargs}
return templates.TemplateResponse("template.html", ctx)
```

## New API (Starlette 1.0+)

```python
ctx = {"user": user, **kwargs}
return templates.TemplateResponse(request, "template.html", ctx)
```

`request` is now the first positional argument, not part of the context dict.

## How We Found It

- Production had the same bug but it only manifested on error paths (duplicate registration, bad login) — happy paths use redirects and never render templates.
- CI integration tests caught it immediately because `test_plan.sh` exercises error paths.
- Stack trace: `jinja2/utils.py LRUCache.__getitem__` — the `request` object (a dict-like Starlette Request) was used as a cache key, which fails because dicts aren't hashable.

## Affected Versions

- Starlette 1.0.0 + Jinja2 3.1.6
- FastAPI pulls Starlette transitively — upgrading FastAPI can trigger this silently.

## Fix Applied

- `api/routes/web.py` — all `TemplateResponse` calls updated, `_flash_context` renamed to `_ctx` and no longer takes `request` (commit `3a4ddea` on `feat/ci-cd`).

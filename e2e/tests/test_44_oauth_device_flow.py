"""Test 44: Full OAuth device flow — sign up, authorize, sync with OAuth tokens.

Requires:
- E2E_CLERK_SECRET_KEY env var (Clerk Backend API key for cleanup)
- CI stack with Clerk env vars configured
- Playwright + Chromium installed

Skipped automatically if E2E_CLERK_SECRET_KEY is not set.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
from datetime import datetime
from urllib.parse import quote

import pytest
import requests
from playwright.async_api import async_playwright, Page

from helpers.clerk import ClerkClient
from helpers.device_flow import start_device_flow, poll_for_tokens
from helpers.vault import write_note

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
WEB_APP_URL = API_URL.replace("/api", "/app")

CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — skipping Clerk browser tests",
)

# CDP plugin path shorthand
_P = "app.plugins.plugins['engram-sync']"


@pytest.fixture
def clerk_client():
    return ClerkClient(CLERK_SECRET)


@pytest.fixture
def test_email():
    ts = datetime.now().strftime("%Y%m%d%H%M%S")
    return f"e2e-clerk-{ts}@test.local"


@pytest.fixture
def test_password():
    return secrets.token_urlsafe(32)


@pytest.mark.asyncio
async def test_full_device_flow(
    vault_a, cdp_a, api_sync, sync_user, clerk_client, test_email, test_password
):
    """Full journey: sign up → device flow → sync with OAuth tokens."""

    # ── 1. Start device flow via API ──────────────────────────────
    ts = datetime.now().strftime("%Y%m%d%H%M%S")
    client_id = f"e2e-playwright-{ts}"
    flow = start_device_flow(API_URL, client_id)
    device_code = flow["device_code"]
    user_code = flow["user_code"]
    logger.info("Device flow started: user_code=%s", user_code)

    # ── 2-3. Browser: sign up + authorize ─────────────────────────
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()

        try:
            await _clerk_sign_up(page, test_email, test_password)
            await _complete_device_flow(page, user_code)
        finally:
            await browser.close()

    # Wrap everything after sign-up in try/finally so Clerk user is always cleaned up
    try:
        # ── 4. Poll for tokens ────────────────────────────────────
        tokens = poll_for_tokens(API_URL, device_code, timeout=30)
        assert "access_token" in tokens, "No access_token in exchange response"
        assert tokens["refresh_token"].startswith("engram_rt_"), (
            f"Refresh token missing prefix: {tokens['refresh_token'][:20]}"
        )
        assert "vault_id" in tokens
        assert tokens.get("user_email") == test_email
        logger.info("Tokens received: vault_id=%s", tokens["vault_id"])

        # ── 5. Reconfigure Obsidian A to use OAuth ────────────────
        original_settings = await cdp_a.evaluate(
            f"JSON.stringify({{apiKey: {_P}.settings.apiKey, "
            f"refreshToken: {_P}.settings.refreshToken, "
            f"vaultId: {_P}.settings.vaultId, "
            f"userEmail: {_P}.settings.userEmail, "
            f"authMethod: {_P}.settings.authMethod || 'apikey'}})"
        )

        try:
            await _swap_to_oauth(cdp_a, tokens)

            # Write a test note and sync
            path = "E2E/OAuthDeviceFlowTest.md"
            content = "# OAuth Device Flow E2E\nSynced with OAuth tokens from Playwright test."
            write_note(vault_a, path, content)

            # Trigger sync
            result = await cdp_a.trigger_full_sync()
            logger.info("Sync result: %s", result)
            assert result.get("pushed", 0) >= 1, f"Expected push, got: {result}"

            # Verify note reached server using OAuth access token
            resp = requests.get(
                f"{API_URL}/notes/{quote(path, safe='')}",
                headers={
                    "Authorization": f"Bearer {tokens['access_token']}",
                    "X-Vault-ID": str(tokens["vault_id"]),
                },
                timeout=10,
            )
            assert resp.status_code == 200, f"Server GET returned {resp.status_code}"
            assert "OAuth Device Flow E2E" in resp.json().get("content", "")

        finally:
            # ── 6. Restore original API key auth ──────────────────
            await _restore_auth(cdp_a, original_settings)

    finally:
        # ── 7. Cleanup: delete Clerk user ─────────────────────────
        clerk_client.cleanup_user(test_email)
        logger.info("Clerk user cleaned up: %s", test_email)


# ── Private helpers ───────────────────────────────────────────────


async def _clerk_sign_up(page: Page, email: str, password: str) -> None:
    """Navigate to sign-up page and create a Clerk account.

    Clerk's <SignUp /> component renders a multi-step form:
    1. Email + Continue button
    2. Password + Continue button
    3. Optional email verification (dev mode may skip this)
    """
    await page.goto(f"{WEB_APP_URL}/sign-up", wait_until="networkidle")

    # Step 1: Enter email
    email_input = page.locator('input[name="emailAddress"]')
    await email_input.wait_for(state="visible", timeout=15000)
    await email_input.fill(email)

    # Click Continue
    continue_btn = page.locator('button:has-text("Continue")')
    await continue_btn.click()

    # Step 2: Enter password
    password_input = page.locator('input[name="password"]')
    await password_input.wait_for(state="visible", timeout=10000)
    await password_input.fill(password)

    # Click Continue
    continue_btn = page.locator('button:has-text("Continue")')
    await continue_btn.click()

    # Wait for redirect to /app (sign-up complete)
    try:
        await page.wait_for_url(f"{WEB_APP_URL}/**", timeout=15000)
        logger.info("Sign-up complete — redirected to app")
    except Exception:
        # Check if we're on a verification step
        verification = page.locator('input[name="code"]')
        if await verification.is_visible():
            logger.warning(
                "Email verification step detected. "
                "Clerk dev instance may require manual verification setup."
            )
            raise RuntimeError(
                "Clerk email verification step not yet automated. "
                "Configure Clerk dev instance to skip email verification, "
                "or set 'Require email verification' to OFF in Clerk Dashboard "
                "→ Email, Phone, Username."
            )


async def _complete_device_flow(page: Page, user_code: str) -> None:
    """Navigate to /app/link and complete the device flow authorization."""
    await page.goto(f"{WEB_APP_URL}/link", wait_until="networkidle")

    # Enter user code (remove dash for input — the form formats it)
    code_input = page.locator('input[placeholder="XXXX-XXXX"]')
    await code_input.wait_for(state="visible", timeout=10000)
    await code_input.fill(user_code.replace("-", ""))

    # Click Verify
    verify_btn = page.locator('button:has-text("Verify")')
    await verify_btn.click()

    # Wait for vault picker — new user has no vaults, auto-shows create
    vault_name_input = page.locator('input[placeholder="Vault name"]')
    await vault_name_input.wait_for(state="visible", timeout=10000)
    await vault_name_input.fill("E2E Test Vault")

    # Click Authorize
    authorize_btn = page.locator('button:has-text("Authorize")')
    await authorize_btn.click()

    # Wait for success message
    success_heading = page.locator("h2:has-text('Vault linked')")
    await success_heading.wait_for(state="visible", timeout=15000)
    logger.info("Device flow authorized in browser")


async def _swap_to_oauth(cdp, tokens: dict) -> None:
    """Reconfigure Obsidian plugin to use OAuth auth via CDP."""
    refresh_token = json.dumps(tokens["refresh_token"])
    vault_id = json.dumps(str(tokens["vault_id"]))
    user_email = json.dumps(tokens.get("user_email", ""))

    js = f"""
    (async function() {{
        const plugin = {_P};
        plugin.settings.apiKey = '';
        plugin.settings.refreshToken = {refresh_token};
        plugin.settings.vaultId = {vault_id};
        plugin.settings.userEmail = {user_email};
        plugin.settings.authMethod = 'oauth';
        await plugin.saveSettings();
        // Reload auth provider
        plugin.authProvider = plugin.createAuthProvider();
        if (plugin.authProvider) {{
            plugin.api.setAuthProvider(plugin.authProvider);
            if (plugin.noteStream) {{
                plugin.noteStream.setAuthProvider(plugin.authProvider);
            }}
        }}
        return 'oauth configured';
    }})()
    """
    result = await cdp.evaluate(js, await_promise=True)
    logger.info("Plugin reconfigured to OAuth: %s", result)
    await cdp.wait_for_plugin_ready(timeout=15)


async def _restore_auth(cdp, original_settings_json: str) -> None:
    """Restore Obsidian plugin to original auth settings via CDP."""
    settings = json.loads(original_settings_json)
    api_key = json.dumps(settings.get("apiKey", ""))
    refresh_token = json.dumps(settings.get("refreshToken", ""))
    vault_id = json.dumps(settings.get("vaultId", ""))
    user_email = json.dumps(settings.get("userEmail", ""))
    auth_method = json.dumps(settings.get("authMethod", "apikey"))

    js = f"""
    (async function() {{
        const plugin = {_P};
        plugin.settings.apiKey = {api_key};
        plugin.settings.refreshToken = {refresh_token};
        plugin.settings.vaultId = {vault_id};
        plugin.settings.userEmail = {user_email};
        plugin.settings.authMethod = {auth_method};
        await plugin.saveSettings();
        plugin.authProvider = plugin.createAuthProvider();
        if (plugin.authProvider) {{
            plugin.api.setAuthProvider(plugin.authProvider);
            if (plugin.noteStream) {{
                plugin.noteStream.setAuthProvider(plugin.authProvider);
            }}
        }}
        return 'auth restored';
    }})()
    """
    result = await cdp.evaluate(js, await_promise=True)
    logger.info("Plugin auth restored: %s", result)
    await cdp.wait_for_plugin_ready(timeout=15)

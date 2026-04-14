#!/usr/bin/env python3
"""Bulk-delete stale E2E test users from a Clerk dev instance.

Usage:
    E2E_CLERK_SECRET_KEY=sk_test_... python e2e/scripts/cleanup_clerk_users.py [--dry-run]

Fetches all Clerk users, filters to e2e-* email patterns, and deletes them.
Designed to recover from the Clerk dev 100-user quota limit.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time

import requests

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

CLERK_API = "https://api.clerk.dev/v1"
E2E_EMAIL_PREFIXES = ("e2e-sync-", "e2e-iso-", "e2e-vault-iso-", "e2e-oauth-", "e2e-clerk-")


def get_all_users(session: requests.Session) -> list[dict]:
    """Paginate through all Clerk users."""
    users = []
    offset = 0
    limit = 100
    while True:
        resp = session.get(
            f"{CLERK_API}/users",
            params={"limit": limit, "offset": offset, "order_by": "created_at"},
            timeout=15,
        )
        resp.raise_for_status()
        batch = resp.json()
        if not batch:
            break
        users.extend(batch)
        if len(batch) < limit:
            break
        offset += limit
    return users


def is_e2e_user(user: dict) -> bool:
    """Check if a Clerk user was created by E2E tests."""
    for ea in user.get("email_addresses", []):
        email = ea.get("email_address", "")
        if any(email.startswith(prefix) for prefix in E2E_EMAIL_PREFIXES):
            return True
    return False


def main():
    parser = argparse.ArgumentParser(description="Delete stale E2E Clerk users")
    parser.add_argument("--dry-run", action="store_true", help="List users without deleting")
    args = parser.parse_args()

    secret = os.environ.get("E2E_CLERK_SECRET_KEY", "")
    if not secret:
        logger.error("E2E_CLERK_SECRET_KEY not set")
        sys.exit(1)

    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {secret}"
    session.headers["Content-Type"] = "application/json"

    logger.info("Fetching all Clerk users...")
    all_users = get_all_users(session)
    logger.info("Total users in instance: %d", len(all_users))

    e2e_users = [u for u in all_users if is_e2e_user(u)]
    non_e2e = len(all_users) - len(e2e_users)
    logger.info("E2E test users: %d | Real users: %d", len(e2e_users), non_e2e)

    if not e2e_users:
        logger.info("Nothing to clean up.")
        return

    for user in e2e_users:
        emails = [ea["email_address"] for ea in user.get("email_addresses", [])]
        email_str = ", ".join(emails)
        if args.dry_run:
            logger.info("[DRY RUN] Would delete: %s (%s)", user["id"], email_str)
        else:
            resp = session.delete(f"{CLERK_API}/users/{user['id']}", timeout=10)
            if resp.status_code == 404:
                logger.warning("Already deleted: %s (%s)", user["id"], email_str)
            elif resp.ok:
                logger.info("Deleted: %s (%s)", user["id"], email_str)
            else:
                logger.error("Failed to delete %s: %s %s", user["id"], resp.status_code, resp.text)
            # Respect rate limits
            time.sleep(0.1)

    logger.info("Done. Deleted %d e2e users.", len(e2e_users))


if __name__ == "__main__":
    main()

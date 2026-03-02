"""brain-indexer: watches Obsidian vault, parses markdown, embeds, stores in Qdrant."""

import json
import logging
import os
import sqlite3
import time
from pathlib import Path

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

from embedders.ollama import embed_texts
from parsers.markdown import parse_markdown
from stores.qdrant_store import (
    delete_by_source,
    ensure_collection,
    get_client,
    upsert_chunks,
)

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("brain-indexer")

VAULT_PATH = Path(os.environ.get("VAULT_PATH", "/vault"))
STATE_DIR = Path(os.environ.get("STATE_DIR", "/state"))
USER_ID = os.environ.get("USER_ID")
COLLECTION = "obsidian_notes"
EMBED_BATCH_SIZE = 32

# Directories/files to skip
SKIP_DIRS = {".obsidian", ".trash", ".git", "_extras"}


def get_state_db() -> sqlite3.Connection:
    """Get or create the SQLite state database for tracking indexed files."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    db_path = STATE_DIR / "indexer_state.db"
    conn = sqlite3.connect(str(db_path))
    conn.execute(
        "CREATE TABLE IF NOT EXISTS indexed_files ("
        "  path TEXT PRIMARY KEY,"
        "  mtime REAL,"
        "  chunk_count INTEGER"
        ")"
    )
    conn.commit()
    return conn


def get_last_mtime(conn: sqlite3.Connection, path: str) -> float | None:
    row = conn.execute("SELECT mtime FROM indexed_files WHERE path = ?", (path,)).fetchone()
    return row[0] if row else None


def set_indexed(conn: sqlite3.Connection, path: str, mtime: float, chunk_count: int) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO indexed_files (path, mtime, chunk_count) VALUES (?, ?, ?)",
        (path, mtime, chunk_count),
    )
    conn.commit()


def remove_indexed(conn: sqlite3.Connection, path: str) -> None:
    conn.execute("DELETE FROM indexed_files WHERE path = ?", (path,))
    conn.commit()


def should_skip(path: Path) -> bool:
    """Check if a path should be skipped."""
    for part in path.parts:
        if part in SKIP_DIRS:
            return True
    return False


def index_file(client, conn: sqlite3.Connection, file_path: Path) -> None:
    """Parse, embed, and store a single markdown file."""
    if should_skip(file_path):
        return
    if file_path.suffix.lower() != ".md":
        return
    if not file_path.exists():
        return

    source_path = str(file_path)
    current_mtime = file_path.stat().st_mtime
    last_mtime = get_last_mtime(conn, source_path)

    if last_mtime is not None and current_mtime <= last_mtime:
        logger.debug("Skipping (unchanged): %s", source_path)
        return

    logger.info("Indexing: %s", source_path)

    try:
        chunks = parse_markdown(file_path, collection=COLLECTION, user_id=USER_ID)
    except Exception:
        logger.exception("Failed to parse: %s", source_path)
        return

    if not chunks:
        logger.warning("No chunks produced for: %s", source_path)
        return

    # Delete old chunks for this file
    delete_by_source(client, COLLECTION, source_path, user_id=USER_ID)

    # Embed in batches
    all_texts = [c.text for c in chunks]
    all_metadatas = [c.metadata for c in chunks]
    all_embeddings: list[list[float]] = []

    for i in range(0, len(all_texts), EMBED_BATCH_SIZE):
        batch = all_texts[i : i + EMBED_BATCH_SIZE]
        try:
            embeddings = embed_texts(batch)
            all_embeddings.extend(embeddings)
        except Exception:
            logger.exception("Embedding failed for batch starting at %d in %s", i, source_path)
            return

    # Upsert to Qdrant
    upsert_chunks(client, COLLECTION, all_texts, all_embeddings, all_metadatas)

    # Update state
    set_indexed(conn, source_path, current_mtime, len(chunks))
    logger.info("Indexed %d chunks from: %s", len(chunks), source_path)


def full_scan(client, conn: sqlite3.Connection) -> None:
    """Scan entire vault and index new/modified files."""
    logger.info("Starting full scan of: %s", VAULT_PATH)
    md_files = list(VAULT_PATH.rglob("*.md"))
    logger.info("Found %d markdown files", len(md_files))

    indexed = 0
    skipped = 0
    for f in md_files:
        if should_skip(f):
            skipped += 1
            continue
        index_file(client, conn, f)
        indexed += 1

    logger.info("Full scan complete. Processed: %d, Skipped: %d", indexed, skipped)

    # Clean up entries for deleted files
    all_paths = {str(f) for f in md_files if not should_skip(f)}
    rows = conn.execute("SELECT path FROM indexed_files").fetchall()
    for (path,) in rows:
        if path not in all_paths:
            logger.info("Removing deleted file from index: %s", path)
            delete_by_source(client, COLLECTION, path, user_id=USER_ID)
            remove_indexed(conn, path)


class VaultHandler(FileSystemEventHandler):
    """Watches for file changes in the vault and re-indexes."""

    def __init__(self, client):
        self.client = client

    def on_modified(self, event):
        if event.is_directory:
            return
        self._handle(Path(event.src_path))

    def on_created(self, event):
        if event.is_directory:
            return
        self._handle(Path(event.src_path))

    def on_deleted(self, event):
        if event.is_directory:
            return
        path = event.src_path
        logger.info("File deleted: %s", path)
        conn = get_state_db()
        try:
            delete_by_source(self.client, COLLECTION, path, user_id=USER_ID)
            remove_indexed(conn, path)
        finally:
            conn.close()

    def on_moved(self, event):
        if event.is_directory:
            return
        src = Path(event.src_path)
        dest = Path(event.dest_path)

        # If moved out of vault or into a skipped dir (e.g. .trash), treat as delete
        if should_skip(dest) or not str(dest).startswith(str(VAULT_PATH)):
            logger.info("File moved to skipped location: %s -> %s", src, dest)
            conn = get_state_db()
            try:
                delete_by_source(self.client, COLLECTION, str(src), user_id=USER_ID)
                remove_indexed(conn, str(src))
            finally:
                conn.close()
        else:
            # Moved within vault (e.g. renamed) — remove old, index new
            logger.info("File moved: %s -> %s", src, dest)
            conn = get_state_db()
            try:
                delete_by_source(self.client, COLLECTION, str(src), user_id=USER_ID)
                remove_indexed(conn, str(src))
                if dest.suffix.lower() == ".md" and not should_skip(dest):
                    index_file(self.client, conn, dest)
            finally:
                conn.close()

    def _handle(self, file_path: Path):
        if file_path.suffix.lower() != ".md":
            return
        if should_skip(file_path):
            return
        # Small delay to let file writes finish
        time.sleep(0.5)
        conn = get_state_db()
        try:
            index_file(self.client, conn, file_path)
        finally:
            conn.close()


def wait_for_qdrant(client, max_retries: int = 30, delay: float = 2.0) -> None:
    """Wait for Qdrant to be available."""
    for i in range(max_retries):
        try:
            client.get_collections()
            logger.info("Qdrant is ready")
            return
        except Exception:
            logger.info("Waiting for Qdrant... (%d/%d)", i + 1, max_retries)
            time.sleep(delay)
    raise RuntimeError("Qdrant did not become available")


def wait_for_ollama(max_retries: int = 30, delay: float = 2.0) -> None:
    """Wait for Ollama to be available and pull model if needed."""
    import httpx

    ollama_url = os.environ.get("OLLAMA_URL", "http://localhost:11434")
    model = os.environ.get("EMBED_MODEL", "nomic-embed-text")

    for i in range(max_retries):
        try:
            resp = httpx.get(f"{ollama_url}/api/tags", timeout=5.0)
            resp.raise_for_status()
            models = [m["name"] for m in resp.json().get("models", [])]
            # Check if model is available (with or without :latest tag)
            if any(model in m for m in models):
                logger.info("Ollama is ready, model '%s' available", model)
                return
            else:
                logger.warning(
                    "Ollama is up but model '%s' not found. Available: %s. "
                    "Please run: ollama pull %s",
                    model,
                    models,
                    model,
                )
                return
        except Exception:
            logger.info("Waiting for Ollama at %s... (%d/%d)", ollama_url, i + 1, max_retries)
            time.sleep(delay)
    raise RuntimeError("Ollama did not become available")


def main():
    logger.info("brain-indexer starting")
    logger.info("Vault path: %s", VAULT_PATH)
    logger.info("State dir: %s", STATE_DIR)
    logger.info("User ID: %s", USER_ID or "(not set — single-user mode)")

    if not VAULT_PATH.exists():
        logger.error("Vault path does not exist: %s", VAULT_PATH)
        raise SystemExit(1)

    client = get_client()
    wait_for_qdrant(client)
    wait_for_ollama()

    ensure_collection(client, COLLECTION)
    conn = get_state_db()

    # Full scan on startup
    full_scan(client, conn)

    # Watch for changes
    logger.info("Starting file watcher on: %s", VAULT_PATH)
    handler = VaultHandler(client)
    observer = Observer()
    observer.schedule(handler, str(VAULT_PATH), recursive=True)
    observer.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
    conn.close()
    logger.info("brain-indexer stopped")


if __name__ == "__main__":
    main()

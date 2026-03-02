"""Embedder factory — selects backend via EMBED_BACKEND env var."""

from config import EMBED_BACKEND


def get_embedder():
    """Return the embed function for the configured backend."""
    if EMBED_BACKEND == "openai":
        from embedders.openai import embed
        return embed
    else:
        from embedders.ollama import embed
        return embed


def get_batch_embedder():
    """Return the embed_batch function for the configured backend."""
    if EMBED_BACKEND == "openai":
        from embedders.openai import embed_batch
        return embed_batch
    else:
        from embedders.ollama import embed_batch
        return embed_batch

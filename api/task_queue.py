"""Async task queue with optional Redis backend for crash-resilient job processing."""

import asyncio
import json
import logging
from concurrent.futures import ThreadPoolExecutor
from typing import Callable

import redis_client

logger = logging.getLogger("engram")

_REDIS_QUEUE_KEY = "taskqueue:index"
_MAX_RETRIES = 3


class TaskQueue:
    """Async task queue that runs sync functions via run_in_executor."""

    def __init__(self, max_workers: int = 3, max_queue_size: int = 1000):
        self._max_workers = max_workers
        self._max_queue_size = max_queue_size
        self._executor = ThreadPoolExecutor(max_workers=max_workers)
        self._workers: list[asyncio.Task] = []
        self._running = False
        self._use_redis = False
        # In-memory queue (used when Redis is not configured)
        self._queue: asyncio.Queue = asyncio.Queue(maxsize=max_queue_size)
        # Registry of callable functions by name (for Redis deserialization)
        self._func_registry: dict[str, Callable] = {}

    def register(self, func: Callable) -> None:
        """Register a function so it can be invoked from Redis job payloads."""
        self._func_registry[func.__name__] = func

    async def start(self) -> None:
        """Start worker coroutines."""
        self._use_redis = redis_client.is_enabled()
        self._running = True
        loop = asyncio.get_event_loop()
        for i in range(self._max_workers):
            task = asyncio.create_task(self._worker(i, loop))
            self._workers.append(task)
        backend = "Redis" if self._use_redis else "in-memory"
        logger.info("Task queue started with %d workers (%s)", self._max_workers, backend)

    async def stop(self) -> None:
        """Drain the queue and stop workers."""
        self._running = False
        if not self._use_redis:
            # Send sentinel values to unblock workers
            for _ in self._workers:
                try:
                    self._queue.put_nowait(None)
                except asyncio.QueueFull:
                    pass
        for task in self._workers:
            task.cancel()
        await asyncio.gather(*self._workers, return_exceptions=True)
        self._executor.shutdown(wait=False)
        self._workers.clear()
        logger.info("Task queue stopped")

    def enqueue(self, func: Callable, *args) -> bool:
        """Enqueue a sync function to run in background. Returns False if queue is full."""
        if self._use_redis:
            return self._enqueue_redis(func, args)
        return self._enqueue_local(func, args)

    def _enqueue_local(self, func: Callable, args: tuple) -> bool:
        try:
            self._queue.put_nowait((func, args))
            return True
        except asyncio.QueueFull:
            logger.warning("Task queue full, dropping task: %s", func.__name__)
            return False

    def _enqueue_redis(self, func: Callable, args: tuple) -> bool:
        try:
            r = redis_client.get_sync()
            # Serialize: store func name + JSON-serializable args + retry count
            payload = json.dumps({
                "func": func.__name__,
                "args": list(args),
                "retries": 0,
            })
            r.lpush(_REDIS_QUEUE_KEY, payload)
            return True
        except Exception:
            logger.warning("Redis enqueue failed, dropping task: %s", func.__name__)
            return False

    async def _worker(self, worker_id: int, loop: asyncio.AbstractEventLoop) -> None:
        """Worker coroutine that processes tasks from the queue."""
        if self._use_redis:
            await self._worker_redis(worker_id, loop)
        else:
            await self._worker_local(worker_id, loop)

    async def _worker_local(self, worker_id: int, loop: asyncio.AbstractEventLoop) -> None:
        while self._running:
            try:
                item = await self._queue.get()
                if item is None:
                    break
                func, args = item
                await loop.run_in_executor(self._executor, func, *args)
            except asyncio.CancelledError:
                break
            except Exception:
                logger.exception("Task queue worker %d error", worker_id)

    async def _worker_redis(self, worker_id: int, loop: asyncio.AbstractEventLoop) -> None:
        while self._running:
            try:
                r_async = redis_client.get_async()
                # BRPOP with 1s timeout to allow checking self._running
                result = await r_async.brpop(_REDIS_QUEUE_KEY, timeout=1)
                if result is None:
                    continue
                _, raw = result
                job = json.loads(raw)
                func_name = job["func"]
                args = job["args"]
                retries = job.get("retries", 0)

                func = self._func_registry.get(func_name)
                if func is None:
                    logger.error("Unknown task function: %s", func_name)
                    continue

                try:
                    await loop.run_in_executor(self._executor, func, *args)
                except Exception:
                    if retries < _MAX_RETRIES:
                        logger.warning(
                            "Task %s failed (attempt %d/%d), re-queuing",
                            func_name, retries + 1, _MAX_RETRIES,
                        )
                        job["retries"] = retries + 1
                        r_sync = redis_client.get_sync()
                        r_sync.lpush(_REDIS_QUEUE_KEY, json.dumps(job))
                    else:
                        logger.exception(
                            "Task %s failed after %d retries, dropping",
                            func_name, _MAX_RETRIES,
                        )
            except asyncio.CancelledError:
                break
            except Exception:
                logger.exception("Task queue worker %d error", worker_id)
                await asyncio.sleep(1)  # back off on unexpected errors

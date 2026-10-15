"""并发闸门。

pandoc 每次转换是个吃内存的子进程，而部署机只有 6GB 内存 —— 必须限制同时在跑的转换数。
另外排队也不能无限深：队列满了就直接拒绝，而不是让请求堆积把内存吃光。
"""
import threading
from contextlib import contextmanager

from . import config


class Busy(Exception):
    """队列已满，拒绝服务。"""


class Limiter:
    def __init__(self, permits: int, max_queue: int):
        self._sem = threading.BoundedSemaphore(permits)
        self._max_queue = max_queue
        self._lock = threading.Lock()
        self._waiting = 0

    @contextmanager
    def slot(self):
        with self._lock:
            if self._waiting >= self._max_queue:
                raise Busy()
            self._waiting += 1
        try:
            self._sem.acquire()
        finally:
            with self._lock:
                self._waiting -= 1
        try:
            yield
        finally:
            self._sem.release()

    @property
    def stats(self) -> dict:
        with self._lock:
            return {
                "max_concurrent": self._sem._initial_value,
                "waiting": self._waiting,
                "max_queue": self._max_queue,
            }


limiter = Limiter(config.MAX_CONCURRENT, config.MAX_QUEUE)

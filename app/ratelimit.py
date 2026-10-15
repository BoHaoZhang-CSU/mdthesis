"""限流 —— 防止公网被白刷。

两层同时生效：

  ① **按 IP**：每个 IP 在时间窗内最多 N 次
  ② **全局**：全站总共最多 M 次

为什么两层都要 —— 因为**经过 frp TCP 隧道时拿不到真实 IP**：
frpc 从 127.0.0.1 连过来，服务看到的客户端 IP 全是 127.0.0.1。
TCP 模式（`type = "tcp"`）不像 http 模式那样会带 `X-Forwarded-For`，
PROXY protocol 又要后端支持（uvicorn 不支持）。

所以：
  - 直连部署 / 用 frp http 模式   → X-Forwarded-For 有效，按 IP 精确限流 ✓
  - frp tcp 模式（当前情况）      → 所有请求挤在一个桶里，退化成全局限流 ✓

全局这层就是给「IP 拿不到」准备的兜底：有人无限刷时，总量会被卡住。

滑动窗口实现，窗口随时间滑动自动过期（不会永久封禁）。
"""
import threading
import time
from collections import defaultdict, deque

from . import config


class _Window:
    """一个 IP 的滑动窗口：只记时间戳，超窗口的自动丢弃。"""

    __slots__ = ("hits",)

    def __init__(self):
        self.hits = deque()


class RateLimiter:
    def __init__(self, per_ip: int, per_global: int, window: int):
        self.per_ip = per_ip
        self.per_global = per_global
        self.window = window
        self._lock = threading.Lock()
        self._ips: dict[str, _Window] = defaultdict(_Window)
        self._global = _Window()
        self._last_gc = 0.0

    def _prune(self, w: _Window, now: float) -> None:
        cut = now - self.window
        while w.hits and w.hits[0] < cut:
            w.hits.popleft()

    def _gc(self, now: float) -> None:
        """定期清掉长期没请求的 IP，避免字典无限膨胀（被扫端口时会塞很多条目）。"""
        if now - self._last_gc < self.window:
            return
        self._last_gc = now
        for ip in [k for k, w in self._ips.items()
                   if not w.hits or w.hits[-1] < now - self.window]:
            del self._ips[ip]

    def check(self, ip: str) -> tuple[bool, str]:
        """返回 (是否放行, 拒绝原因)。放行时会记一次。"""
        now = time.time()
        with self._lock:
            self._gc(now)

            self._prune(self._global, now)
            if len(self._global.hits) >= self.per_global:
                retry = max(1, int(self._global.hits[0] + self.window - now))
                return False, (f"服务整体繁忙（{self.window} 秒内已达 {self.per_global} 次上限），"
                               f"请 {retry} 秒后重试")

            w = self._ips[ip]
            self._prune(w, now)
            if len(w.hits) >= self.per_ip:
                retry = max(1, int(w.hits[0] + self.window - now))
                return False, (f"转换过于频繁（{self.window} 秒内已达 {self.per_ip} 次上限），"
                               f"请 {retry} 秒后重试")

            w.hits.append(now)
            self._global.hits.append(now)
            return True, ""

    @property
    def stats(self) -> dict:
        now = time.time()
        with self._lock:
            self._prune(self._global, now)
            return {
                "per_ip": self.per_ip,
                "per_global": self.per_global,
                "window_seconds": self.window,
                "global_used": len(self._global.hits),
                "tracked_ips": len(self._ips),
            }


limiter = RateLimiter(config.RATE_PER_IP, config.RATE_GLOBAL, config.RATE_WINDOW)

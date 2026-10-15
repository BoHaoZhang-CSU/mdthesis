"""服务配置。全部走环境变量，默认值偏保守 —— 目标部署机只有 6GB 内存。"""
import os
from pathlib import Path

# 项目根目录（app/ 的上一级）
ROOT = Path(__file__).resolve().parent.parent
TEMPLATES_DIR = Path(os.getenv("TEMPLATES_DIR", ROOT / "assets" / "templates"))
CONVERT_SH = Path(os.getenv("CONVERT_SH", ROOT / "tools" / "convert.sh"))
PREPARE_TEMPLATE = Path(os.getenv("PREPARE_TEMPLATE", ROOT / "tools" / "prepare_template.py"))

# 请求工作目录的根。**必须落在磁盘上，不能是 /tmp** ——
# 本机 /tmp 是 3.6GB 的 tmpfs，临时文件直接吃内存；服务器上同样常见 tmpfs。
# 所有请求目录都在这里建，转换子进程的 TMPDIR 也指向它，
# 收尾时一次 rmtree 全清（不依赖 convert.sh 的 trap —— bash 被 SIGKILL 时 trap 不执行）。
WORK_ROOT = Path(os.getenv("WORK_ROOT", "/var/tmp/pandoc-web"))

# 转换子进程里禁掉出网（把代理指向一个死地址）。这是纵深防御：
# filter 已经拦了外部图片/链接，这里再断一层网络，万一 filter 有绕过也打不出去。
BLOCK_NETWORK = os.getenv("BLOCK_NETWORK", "1") != "0"
DEAD_PROXY = "http://127.0.0.1:1"


def _int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, default))
    except ValueError:
        return default


# --- 限流（公网部署防白刷）---
# 经过 frp TCP 隧道时拿不到真实 IP，所有请求会挤成一个桶，
# 那时 per_ip 这层失效、只剩下 per_global 兜底 —— 所以全局值要给得够用又不失控。
# 数值取的是「覆盖真实批量场景、但能挡住脚本刷」：
#   40 次/分钟 ≈ 连续转 40 个文件（约 1 分钟转完）—— 够老师批改一个班
#   80 次/分钟 ≈ 3M 带宽能承载的量级，再多也是带宽先饱和
# 真正兜底的是带宽 + 并发闸门（MAX_CONCURRENT/MAX_QUEUE），限流只是补一层
RATE_WINDOW = _int("RATE_WINDOW", 60)        # 时间窗（秒），窗口滑动自动过期
RATE_PER_IP = _int("RATE_PER_IP", 40)        # 每个 IP 每窗口最多几次
RATE_GLOBAL = _int("RATE_GLOBAL", 80)        # 全站每窗口最多几次

# --- 并发与超时（内存紧张，默认串行）---
MAX_CONCURRENT = _int("MAX_CONCURRENT", 1)
MAX_QUEUE = _int("MAX_QUEUE", 8)  # 排队超过这个数直接返回 503，不无限堆请求
CONVERT_TIMEOUT = _int("CONVERT_TIMEOUT", 120)  # 秒

# --- 上传体积 ---
MAX_MD_BYTES = _int("MAX_MD_BYTES", 5 * 1024 * 1024)  # 5 MB，markdown 是纯文本，够大了
MAX_TEMPLATE_BYTES = _int("MAX_TEMPLATE_BYTES", 20 * 1024 * 1024)  # 20 MB

# --- 不可信 docx 的 zip 安全阈值 ---
MAX_ZIP_ENTRIES = _int("MAX_ZIP_ENTRIES", 2000)
MAX_UNCOMPRESSED_BYTES = _int("MAX_UNCOMPRESSED_BYTES", 200 * 1024 * 1024)  # 解压后总量上限
MAX_COMPRESSION_RATIO = _int("MAX_COMPRESSION_RATIO", 120)  # 单条目压缩比上限，防 zip bomb

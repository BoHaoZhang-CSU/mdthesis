"""pandoc-web HTTP 服务。

设计要点：
  - 转换是阻塞式子进程，端点用 async 读上传、再用线程池跑转换，避免卡住事件循环
  - 全局并发闸门（默认 1）—— 部署机只有 6GB 内存，同时跑多个 pandoc 会 OOM
  - 每请求独立临时目录，用完即焚，服务无状态、不落盘
"""
import base64
import json

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from starlette.concurrency import run_in_threadpool

from . import config, convert, normalize
from .limits import Busy, limiter
from .ratelimit import limiter as rate_limiter
from .validate import UploadError, check_docx_safety, check_md_size

DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
MAX_WARNING_HEADER = 3000  # 响应头别太大，超了只给条数
INDEX_HTML = config.ROOT / "app" / "static" / "index.html"

app = FastAPI(
    title="pandoc-web 转换服务",
    description=(
        "把 markdown 转成按论文模板排版的 Word 文档。\n\n"
        "- **用户内容一个字不改** —— 字体、章节编号、分页全部由 Word 模板的样式决定\n"
        "- **网页界面**：浏览器打开 [/](/) 即可，不用看这里的接口文档\n"
        "- 一份文档的排版是否正常，取决于 markdown 的标题层级是否规范，"
        "详见项目里的 `docs/markdown-规范.md`"
    ),
    version="0.1.0",
)


# ---------- 异常 → HTTP ----------

@app.exception_handler(UploadError)
async def _upload_error(_req, exc: UploadError):
    return JSONResponse({"error": exc.message}, status_code=exc.status)


@app.exception_handler(convert.ConvertError)
async def _convert_error(_req, exc: convert.ConvertError):
    body = {"error": exc.message}
    if exc.detail:
        body["detail"] = exc.detail
    return JSONResponse(body, status_code=exc.status)


def _client_ip(request) -> str:
    """取客户端 IP。

    直连或用 frp http 模式时有 X-Forwarded-For；frp **tcp** 模式下拿不到，
    全部是 127.0.0.1 —— 那时按 IP 这层退化成全局那层（ratelimit.py 有说明）。
    """
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _check_rate(request) -> None:
    """限流检查，超了抛 429。受保护的端点进来先调它。"""
    ok, why = rate_limiter.check(_client_ip(request))
    if not ok:
        raise HTTPException(status_code=429, detail=why)


# ---------- 工具 ----------

async def _read_upload(up: UploadFile, limit: int, what: str) -> bytes:
    """分块读取并限流，避免一次性把超大文件读进内存。"""
    chunks, total = [], 0
    while True:
        chunk = await up.read(64 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise UploadError(
                f"{what}过大，超过上限 {limit / 1048576:.0f} MB", status=413
            )
        chunks.append(chunk)
    return b"".join(chunks)


def _b64(obj) -> str:
    return base64.b64encode(
        json.dumps(obj, ensure_ascii=False).encode("utf-8")
    ).decode("ascii")


def _result_headers(result: convert.ConvertResult) -> dict:
    """把告警/修复记录放进响应头。

    ⚠️ HTTP 头是 latin-1 的，中文必须 base64 —— 否则 starlette 编码时直接
    UnicodeEncodeError 把整个请求打成 500（连文件都拿不到）。
    长度也要有界：告警内容随用户输入增长，全放头里会超反代的 header 缓冲上限。
    """
    headers = {
        "X-Warnings-Count": str(len(result.warnings)),
        "X-Changes-Count": str(len(result.changes)),
        "X-Guesses-Count": str(len(result.guesses)),
        "X-Stats-Count": str(len(result.stats)),
    }
    if result.warnings or result.changes or result.guesses or result.stats:
        blob = _b64({
            "warnings": result.warnings,
            "changes": result.changes,
            "guesses": result.guesses,
            "stats": result.stats,
        })
        if len(blob) <= MAX_WARNING_HEADER:
            headers["X-Report"] = blob
    return headers


# ---------- 路由 ----------

@app.get("/", include_in_schema=False)
async def index():
    """中文网页面板。"""
    if not INDEX_HTML.is_file():
        return JSONResponse({"error": "网页界面文件缺失"}, status_code=500)
    return FileResponse(INDEX_HTML, media_type="text/html; charset=utf-8")


@app.get("/health", summary="服务状态", description="探针接口：返回服务是否正常、pandoc 版本、可用模板、并发配置。")
async def health():
    return {
        "status": "ok",
        "pandoc": convert.pandoc_version(),
        "templates": convert.available_templates(),
        "limits": limiter.stats,
        "ratelimit": rate_limiter.stats,
    }


@app.get("/templates", summary="列出可用模板", description="返回内置的论文模板文件名列表，`/convert` 的 `template` 参数从这里选。")
async def templates():
    return {"templates": convert.available_templates()}


@app.post("/check", summary="检查格式（不转换）",
          description="只检查 markdown 的标题层级是否符合规范，不生成 Word。\n\n"
                      "返回三部分：`warnings`（发现的问题）、`changes`（可以自动修复的地方）、"
                      "`guesses`（需要判断的地方系统猜了什么）。")
async def check(request: Request, file: UploadFile = File(..., description="要检查的 markdown 文件")):
    """只检查不转换，返回告警、会自动做的改动、以及需要判断的地方。

    报告与 `/convert` **同源**（都来自同一个 filter），所以两边结论一定一致。
    """
    _check_rate(request)
    md = await _read_upload(file, config.MAX_MD_BYTES, "markdown 文件")
    check_md_size(md)

    try:
        with limiter.slot():
            warnings, changes, guesses = await run_in_threadpool(convert.run_check, md)
    except Busy:
        raise HTTPException(status_code=503, detail="服务繁忙，请稍后重试")

    return {
        "ok": not warnings,
        "warnings": warnings,
        "changes": changes,
        "guesses": guesses,
    }


@app.post("/normalize", summary="自动修复格式",
          description="自动修掉 markdown 里不合规的地方（标题里手写的编号、多余的章节分隔线等），"
                      "返回修好的全文。\n\n"
                      "**请务必看 `guesses`** —— 有些地方（比如多个一级标题哪个是论文大标题）"
                      "必须做判断，那里会明确告诉系统猜了什么。")
async def normalize_md(request: Request, file: UploadFile = File(..., description="要修复的 markdown 文件")):
    """自动修复 markdown 并返回修好的内容。

    changes 是无需判断的修复；guesses 是需要判断的地方猜了什么 —— 请务必看 guesses。
    """
    _check_rate(request)
    md = await _read_upload(file, config.MAX_MD_BYTES, "markdown 文件")
    check_md_size(md)
    text = md.decode("utf-8", errors="replace")
    fixed, changes, guesses = normalize.normalize(text)

    # 修复后还有没有告警？跑一遍 check 确认（run_check 返回三元组）
    remaining: list[str] = []
    try:
        with limiter.slot():
            warnings, _, _ = await run_in_threadpool(
                convert.run_check, fixed.encode("utf-8")
            )
            remaining = warnings
    except Busy:
        pass  # 修复结果照样返回，只是没附上复查结果

    return {
        "markdown": fixed,
        "changes": changes,
        "guesses": guesses,
        "remaining_warnings": remaining,
    }


@app.post("/convert", summary="转换并下载 Word（自动修复格式）",
          description="上传 markdown，**服务会先把格式问题自动修好，再转换**，直接返回排好版的 .docx。\n\n"
                      "用户不需要「拿回去改完再传一遍」。修了什么、哪里是猜的，"
                      "通过响应头 `X-Report`（base64 JSON，含 `changes` / `guesses` / `warnings`）回报。\n\n"
                      "若不想要自动修复，传 `auto_fix=false`。")
async def convert_md(
    request: Request,
    file: UploadFile = File(..., description="要转换的 markdown 文件"),
    template: str | None = Form(None, description="内置模板名（见「列出可用模板」），不填用默认模板"),
    template_file: UploadFile | None = File(
        None, description="自定义模板 docx。填了就用它，忽略上面的内置模板名"
    ),
):
    """转换成 docx。自动修复 + 告警通过 X-Report 响应头返回（base64 JSON）。"""
    _check_rate(request)
    md = await _read_upload(file, config.MAX_MD_BYTES, "markdown 文件")
    check_md_size(md)

    uploaded: bytes | None = None
    if template_file is not None and template_file.filename:
        uploaded = await _read_upload(
            template_file, config.MAX_TEMPLATE_BYTES, "模板文件"
        )
        if not uploaded:
            raise UploadError("模板文件是空的")
        # 在临时目录外先做 zip 层面校验（check_docx_safety 需要一个真实文件）
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory(prefix="pandocweb-tpl-") as tmp:
            probe = Path(tmp) / "probe.docx"
            probe.write_bytes(uploaded)
            check_docx_safety(probe)

    tpl_path = convert.resolve_template(template)

    try:
        with limiter.slot():
            result = await run_in_threadpool(
                convert.run_convert, md, tpl_path, uploaded
            )
    except Busy:
        raise HTTPException(status_code=503, detail="服务繁忙，请稍后重试")

    headers = _result_headers(result)
    headers["Content-Disposition"] = 'attachment; filename="output.docx"'
    return Response(content=result.docx, media_type=DOCX_MIME, headers=headers)

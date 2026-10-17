# pandoc-web —— markdown → 论文排版 docx 的转换服务
#
# ── 为什么用 debian:bookworm-slim ──────────────────────────────────────────
# 目标部署机是 Radxa A7S（Debian 12，内核偏老）。容器共享宿主机内核，
# 只有用户态是镜像里的 —— 所以镜像的用户态必须比宿主机内核更"老"才安全。
#
#   ubuntu:26.04  → glibc 2.43   （赌它的内核底线低于 A7S 的内核，查不到确切值）
#   debian:12     → glibc 2.36   （就是 A7S 自己的用户态，保证能跑）
#
# 而且 pandoc 走官方**静态**二进制，精确钉在 3.7.0.2，连 glibc 都不依赖。
#
# ── 构建时若需要代理 ──────────────────────────────────────────────────────
#   docker compose build \
#     --build-arg HTTP_PROXY=http://127.0.0.1:7897 \
#     --build-arg HTTPS_PROXY=http://127.0.0.1:7897
# 注意 build 容器里的 127.0.0.1 是容器自己，要配合 --network=host。
# compose 里已经配好了。目标机若能直连外网就不需要这些参数。

FROM debian:bookworm-slim

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG PANDOC_VERSION=3.7.0.2
# 与本机开发环境一致的版本，避免行为漂移
ARG FASTAPI_VERSION=0.118.0
ARG UVICORN_VERSION=0.38.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUTF8=1 \
    PYTHONIOENCODING=utf-8 \
    PYTHONDONTWRITEBYTECODE=1

# 压缩包解压：7zz 解 7z，bsdtar（libarchive）解 rar。
# Debian 主仓库的 7zip 不含 unRAR 代码（在 non-free），所以 rar 走 bsdtar。
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        python3 \
        python3-pip \
        tini \
        7zip \
        libarchive-tools \
    && rm -rf /var/lib/apt/lists/*

# pandoc：官方静态 arm64 二进制。静态链接 ⇒ 不依赖镜像里的 glibc，
# 也就不会因基座/宿主机 glibc 差异出问题。
#
# ⚠️ tarball 里的 bin/pandoc、bin/pandoc-lua、bin/pandoc-server 是**同一个 165MB
# 二进制**（md5 完全相同，靠 argv[0] 区分行为）。早先用 `install .../bin/*`
# 把它们拷了三份，白白多占 345MB。这里只装 `pandoc` —— 服务只用到它。
RUN set -eux; \
    curl -fsSL --retry 3 -o /tmp/pandoc.tar.gz \
      "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-arm64.tar.gz"; \
    tar -xzf /tmp/pandoc.tar.gz -C /tmp; \
    install -m 0755 /tmp/pandoc-${PANDOC_VERSION}/bin/pandoc /usr/local/bin/pandoc; \
    rm -rf /tmp/pandoc*; \
    pandoc --version | head -1

# 版本必须落在 3.7.x。Ubuntu/Debian 若变更上游版本，这里直接让构建失败，
# 而不是悄悄产出一个没验证过的镜像。
RUN pandoc --version | head -1 | grep -q "^pandoc 3\.7\." \
    || { echo "pandoc 版本不是 3.7.x，filter 未在此版本上验证过"; pandoc --version | head -1; exit 1; }

# python-multipart 是 FastAPI 处理文件上传的必需依赖，容易漏
RUN pip3 install --no-cache-dir --break-system-packages \
        "fastapi==${FASTAPI_VERSION}" \
        "uvicorn==${UVICORN_VERSION}" \
        "python-multipart"

# ── 许可合规 ────────────────────────────────────────────────────────────────
# 本镜像**再分发** pandoc（GPL-2+），必须随它附上版权与许可证声明。
# pandoc 是从官方 tarball 安装的，不像 apt 安装会自动带 /usr/share/doc/pandoc，
# 所以这里手工补一份（对应源码链接也在里面）。
COPY packaging/pandoc-copyright.txt /usr/share/doc/pandoc/copyright
COPY LICENSE THIRD-PARTY.md /usr/share/doc/pandoc-web/

WORKDIR /app

COPY LICENSE THIRD-PARTY.md ./
COPY app/      ./app/
COPY filters/  ./filters/
COPY tools/    ./tools/
COPY assets/   ./assets/
COPY tests/    ./tests/
COPY docs/     ./docs/
COPY README.md ./

RUN chmod +x tools/convert.sh tools/*.py tests/*.sh

# 构建期冒烟测试：pandoc 版本漂移、locale 配错、模板漏拷、filter 行为变化，
# 都在这一步暴露 —— 而不是等上线后在用户文档上暴露。
RUN OUTDIR=/tmp/regression ./tests/regression.sh

RUN useradd -u 10001 -m -d /home/web -s /usr/sbin/nologin web \
    && mkdir -p /work \
    && chown -R 10001:10001 /work

# 请求工作目录。**必须落在卷上（磁盘）**，不能是 /tmp ——
# 宿主机的 /tmp 是 tmpfs，临时文件会吃内存。
ENV WORK_ROOT=/work \
    HOME=/work \
    MAX_CONCURRENT=1 \
    MAX_QUEUE=8 \
    CONVERT_TIMEOUT=120

USER 10001
EXPOSE 8000

# tini 做 PID 1：容器里没有 init 的话，被杀的子进程会变成僵尸永久堆积。
# 放进 ENTRYPOINT 而不是依赖 `docker run --init`，这样 compose/k8s 下同样有效。
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python3", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

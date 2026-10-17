# mdthesis

**把你的 Word 模板扔进来就行，不用写配置。**

Markdown → 毕业论文 Word（.docx）。版式（章节编号、分页、字体、三线表、目录）
全部由你的 Word 模板决定 —— 而且**不用像别的工具那样手写 `format.yaml` 去描述字体字号**，
程序会读你的模板、自己认出来。

<p align="center">
  <img src="docs/screenshot.png" alt="转换界面" width="560">
</p>

---

## 和同类工具的差别

| | 常见做法 | 本项目的做法 |
|---|---|---|
| 换学校 / 换模板 | 改 `format.yaml`，把字体字号间距缩进**手写一遍** | **上传模板就行**，样式自动识别 |
| 章节样式名不标准 | 转换失败，或静默套错格式 | 按**大纲级别 + 使用次数**识别，自动改名适配 |
| 模板缺样式 | 输出回落成 Word 默认格式 | 从内置基准模板**补齐**，不回落 |
| 用户的 markdown | 要求先改好再传 | **自动修复**（编号、目录、分隔线），直接出结果 |

**核心原则：你的正文一个字都不会被改。** 改的只是标题层级和分隔线这类排版信息，
而且每一步都会告诉你改了什么。

> 2026-10-17 这轮改动（图片/Obsidian、压缩包 zip/tar/7z/rar、代码块公式、
> 列表去项目符号、不编号章节、WPS 目录空白页）的根因和做法，见
> [`docs/踩坑与解决方案.md`](docs/踩坑与解决方案.md)。

## 三种用法

**① 网页版**（给不写代码的人）

```bash
docker compose up -d --build      # 打开 http://127.0.0.1:8000
```

拖入 `.md` 或压缩包（zip / tar / 7z / rar），点一下，Word 直接下载。
支持一次拖多个、md + 图片、模板上传、自动修复。

**② 命令行**

```bash
./tools/convert.sh 你的论文.md 输出.docx
```

**③ HTTP API**

```bash
curl -X POST http://127.0.0.1:8000/convert \
  -F "file=@你的论文.md" -o 输出.docx
```

---

## 依赖

| 组件 | 版本 | 用途 |
|---|---|---|
| `pandoc` | **3.7.x** | 转换引擎 |
| `python3` | 3.9+ | 服务与后处理脚本（**只用标准库**，无第三方依赖） |

```bash
sudo apt install pandoc python3
```

> ⚠️ **pandoc 请保持 3.7.x**。filter 依赖这个版本的具体行为
> （例如 `pandoc.Para` 没有 `.attr` 字段），换大版本可能出问题。
> 换机器后**务必跑一遍回归测试**，它会直接告诉你环境有没有漂移。

---

## ⚠️ 先准备模板

**本仓库不附带 Word 模板** —— 模板是需要自行准备的资产。

把 `.docx` 放进 `assets/templates/`，加工一次即可：

```bash
python3 tools/prepare_template.py 你的模板.docx assets/templates/你的模板.docx
```

- 模板必须有 **`heading 2`** 样式（章节用），否则加工会直接报错并说明原因
- 章节样式的大纲级别建议设对 —— 这样即使样式名是自定义的（如「一级标题」）也能自动识别
- 大标题 / 摘要 / 目录标题的样式缺了会自动补齐，表格样式会按模板声明渲染三线表

详见 [`assets/templates/README.md`](assets/templates/README.md)。

## 快速开始

```bash
# 用 assets/templates/ 里的模板（放哪个名字就用哪个）
./tools/convert.sh 你的文档.md 输出.docx

# 换模板（把新模板放进 assets/templates/ 后）
./tools/convert.sh 你的文档.md 输出.docx assets/templates/别的模板.docx

# 或用环境变量
THESIS_TEMPLATE=/path/to/模板.docx ./tools/convert.sh 你的文档.md 输出.docx
```

**markdown 怎么写见 [`docs/markdown-规范.md`](docs/markdown-规范.md)** ——
那份文档里还有一段可直接复制给 AI 的提示词，用来把不合规的 md 改写成合规版本。

> 不过走 HTTP 服务时**不需要用户自己改** —— `/convert` 会先自动修复再转换。
> 规范文档主要给命令行用户和 API 调用方参考。

---

## 目录结构

```
pandoc-web/
├── assets/
│   ├── templates/
│   │   └── 毕业论文通用模板.docx   ← 唯一的模板，转换默认用它
│   └── sources/
│       └── 凝视与回应_论文润色完善版.docx  原始素材（重新加工模板时才用得到）
├── app/                    HTTP 服务（FastAPI）
│   ├── main.py             路由
│   ├── convert.py          调 tools/convert.sh + 自动修复
│   ├── normalize.py        markdown 修复逻辑
│   ├── validate.py         上传校验（zip 加固）
│   ├── archive.py          压缩包解包（zip / tar / 7z / rar）
│   ├── limits.py           并发闸门
│   └── static/index.html   中文网页面板
├── deploy/
│   └── docker-compose.yml  纯运行版 compose（给老 Docker 的目标机用）
├── docs/
│   ├── markdown-规范.md     书写规范 + 给 AI 的提示词
│   └── 踩坑与解决方案.md     2026-10-17 这轮的根因与修法
├── filters/
│   └── thesis_template.lua  模板适配逻辑（改行为改这里）
├── tools/
│   ├── convert.sh           一键流程 ← CLI 主入口
│   ├── prepare_template.py  从原始模板加工出 pandoc 专用模板
│   ├── resolve_resources.py 图片路径 / Obsidian 嵌入解析
│   └── strip_unused_media.py 剥离 pandoc 带入的无用图片（安全网）
└── tests/
    ├── 论文1.md / .docx      主用例与产出
    ├── 论文1_预览.pdf        渲染预览（LibreOffice 转的，仅供参考）
    ├── cases/               25 个刁钻边界用例
    └── regression.sh        回归测试，118 项断言
```

---

## filter 做了什么

`filters/thesis_template.lua` 负责把 markdown 的层级映射到模板样式：

| markdown | 输出 |
|---|---|
| `# 标题`（全文仅一个） | 「摘要上标题」样式，18pt 黑体居中，不编号 |
| `## 摘要` | 「摘要」样式，**脱离自动编号序列** |
| `## 引言` | `heading 2` → Word 自动生成「第N章 引言」，每章另起一页 |
| `### 研究背景` | `heading 3` → 自动生成「N.M 研究背景」 |
| `## 参考资料` 下的列表 | 拆成普通段落 + `[N]` 前缀 |
| `---` | 紧挨标题的丢弃；其余渲染成段落下边框横线 |

**多个 `#` 时会输出警告**，提示用户修改 markdown（不猜哪个是论文大标题）。

---

## 换模板怎么办

```bash
# 1. 把新模板的原始文件放进 assets/sources/
# 2. 加工成 pandoc 专用模板
python3 tools/prepare_template.py assets/sources/新模板.docx assets/templates/新模板_pandoc.docx
# 3. 转换时指定
./tools/convert.sh 文档.md 输出.docx assets/templates/新模板_pandoc.docx
```

`prepare_template.py` 会做两件事：给 `heading 2` 加 `pageBreakBefore`（每章另起一页）、
剥掉模板自带图片。**如果新模板的样式名不是标准的 `heading 2`**，可能需要调整该脚本或 filter。

---

## 测试

```bash
./tests/regression.sh          # 跑全部（10 个边界用例 + 主文档基线）
./tests/regression.sh T1 T4    # 只跑名字含 T1/T4 的
```

改完 `filters/` 或 `tools/` 后**务必跑一遍**。

找不到模板时，测试会用 **pandoc 自带的中性模板**临时生成一份来跑
（生成物在 `tests/.out/.demo/`，不进仓库）—— 这样 clone 下来就能验证功能。
这种情况下依赖特定模板版式的基线断言会跳过，并有明确提示。

---

## HTTP 服务

```bash
docker compose up -d --build
./tests/api_smoke.sh http://127.0.0.1:8000
```

接口：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 探针 + pandoc 版本 + 可用模板 |
| GET | `/templates` | 列出内置模板 |
| POST | `/check` | 只校验，返回告警 / 修复建议 / 猜测说明 |
| POST | `/normalize` | 自动修复 markdown 并返回修好的内容 |
| POST | `/convert` | 上传 md 或压缩包（zip/tar/7z/rar，+可选图片 / 模板）→ 返回 docx 或 zip |

告警通过响应头返回：`X-Warnings-Count`（条数）+ `X-Warnings`（base64 JSON，仅在较短时带上）。
**全文告警请用 `/check`** —— 头部只放有界摘要，避免随用户输入无限膨胀。
`X-Output-Name`（base64）是建议的下载名（zip 里单个 md 时用内层 md 的名字）。

### 图片

`/convert` 的 `file` 可以是 `.md`，也可以是包含 md+图片的压缩包
（zip / tar / tar.gz / tar.bz2 / tar.xz / 7z / rar，按文件头识别，扩展名无所谓）；
图片也可以用 `images` 字段单独传（可多张）。

- 引用写 `![](figs/a.png)` 或 Obsidian 的 `![[figs/a.png]]` 都行；
  **文件夹名不必一致** —— 会按文件名在整个包里找（`a.png` ↔ `figures/a.png`）。
  md 在 `reports/`、图片在 `../figures/` 这种布局也支持。
- 压缩包里只转 `.md` / `.markdown`，CSV / JSON / TXT 等一律忽略。
- 加密压缩包不支持；压缩包里的符号链接会被拒绝；单文件 `.gz/.bz2/.xz` 需先打成 tar。
- 7z/rar 解压依赖 `7z`/`7zz` 或 `bsdtar`（Dockerfile 已装 `7zip` + `libarchive-tools`）。
  极少数使用特殊压缩方法的 RAR5 可能两个工具都解不了，建议改用 zip 重新打包。
- md + 图片分开传：一个请求一个 md，图片跟着它走。
- 压缩包：1 个 md → 返回 docx；多个 md → 每个一个 docx，打包成 zip 返回
  （大标题取文件名，空 md 也出一个空 docx）。
- 限额：单张 10 MB、一批 50 MB / 60 张、压缩包 60 MB（解压后 200 MB）。
  只收 png/jpg/gif/bmp/webp/tif，按文件头校验，不是图片直接拒。

### 代码块与行内代码

- ` ```math ` / ` ```latex ` 代码块无条件当公式；` ```python ` / ` ```bash ` /
  ` ```code ` 等语言标记永远是代码。
- ` ```text ` / 无语言：像公式的行（有 `=`、无代码语法）转成 Word 公式并按章编号，
  其余行转普通正文；像代码的块保持 Source Code。
- 行内代码转普通文本（等宽字体对中文、路径、URL 不友好）；行内公式请用 `$…$`。
- 这些判断通过 `X-Report` 的 `guesses` 汇报，误判时改语言标记即可。

### 列表

- 无序列表（`-` / `*`）转成正文段落，不使用 Word 项目符号：
  一级项首行缩进 2 字；二级及以下左缩进 2 字符/级 +「（1）（2）」编号
  （每个父项内重新计数）。这是学位论文/报告的通行规范（GB/T 7713.1）。
- 有序列表（`1.` / `2.`）保持 Word 自动编号，不动。
- 嵌套建议不超过 3 级。

环境变量（都有保守默认值，部署机 6GB 内存就按默认走）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `MAX_CONCURRENT` | 1 | 同时进行的转换数。pandoc 单次峰值约 140MB，别往大开 |
| `MAX_QUEUE` | 8 | 排队上限，超了直接 503 |
| `CONVERT_TIMEOUT` | 120 | 单次转换超时（秒） |
| `WORK_ROOT` | `/work` | 请求工作目录，**必须落在磁盘上**，见下 |
| `BLOCK_NETWORK` | 1 | 把子进程代理指向死地址，禁掉出网 |

### 验证（三层，都在本机实测通过）

```bash
./tests/regression.sh                                   # ① CLI 层：55 项
./tests/api_smoke.sh http://127.0.0.1:8000              # ② HTTP 层：20 项
docker compose exec -T pandoc-web ./tests/regression.sh # ③ 容器内：55 项
```

> `regression.sh` 在容器里会自动把输出目录降级到 `/work`（根文件系统是只读的），
> 看到「`/app/tests/.out` 不可写」这句是正常的。

**等价性检查**：容器产出的 docx 与宿主机产出的，除 `docProps/core.xml`（含时间戳）外
**逐部件字节相同**，说明容器环境与开发环境行为一致。

### 迁移到另一台机器

**流程已在真实机器上验证过**（arm64 开发板 / Debian 12 / Docker 20.10.24 /
docker-compose 1.29.2，92 MB 走局域网 6.6 秒传完，载入 → 启动 → 转换 → 73+41 项测试全绿）。

**先体检目标机**，这三项不对后面全是白费：

```bash
uname -m                    # 必须是 aarch64
docker --version            # 20.10 以上
docker compose version      # v2 插件
docker-compose --version    # v1 独立版（两者只会有其一）
df -h /                     # 至少留 1 GB
```

> ⚠️ **镜像只能在 arm64 上跑**。x86_64 的机器载入后会报 `exec format error`，
> 得在目标机原生 `docker compose build`。

```bash
# 源机
docker save pandoc-web:0.1.0 | gzip > mdthesis-image.tar.gz          # 约 91 MB
scp -r mdthesis-image.tar.gz deploy/ 对方@主机:~/

# 目标机
gunzip -c mdthesis-image.tar.gz | docker load

docker compose -f deploy/docker-compose.yml up -d          # v2 插件
# 或 docker-compose -f deploy/docker-compose.yml up -d     # v1 独立版

curl -s http://127.0.0.1:8000/health                        # 应返回 status: ok
docker compose exec -T pandoc-web ./tests/regression.sh     # 73 项，全绿即环境正常
rm mdthesis-image.tar.gz
```

#### 两个实测踩过的坑

**① compose 有 v1 / v2 两套，命令不同**

`docker compose`（v2 插件，带空格）和 `docker-compose`（v1 独立版，带连字符）**不是一回事**。
Debian 12 默认装的是 **v1**，敲 v2 的命令会报 `'compose' is not a docker command`。

**务必用 `deploy/docker-compose.yml`**：根目录那份含 `build.provenance` / `sbom`
（新版 compose spec 才有的 key），**v1 会直接报「Unsupported config option」**。
`deploy/` 那份是纯运行版（无 build 段）+ `version: "2.4"`，两代都认。

> 新版 compose 会提示 `version` 已废弃 —— 正常，**别删**，v1 靠它判断格式。

**② 老 Docker 不认新镜像格式**

构建时关掉了 provenance/SBOM attestation（compose 里 `provenance: false`），
否则 **Docker 20.10 这类老版本 load 不了**。已验证 `docker save` 产物根目录有
`manifest.json`（经典格式），20.10 能正常载入。

**目标机还需要**：Docker 已安装并运行，当前用户加入 `docker` 组（`sudo usermod -aG docker $USER`，
然后重新登录）。

### 基座选型：为什么是 Debian 12

容器共享**宿主机内核**，只有用户态来自镜像 —— 所以看的是「镜像的用户态能不能跑在目标内核上」。
实测过的目标机覆盖内核 5.15 ~ 6.1，都不构成约束。

| 基座 | glibc | Python | 结论 |
|---|---|---|---|
| `ubuntu:26.04` | 2.43 | 3.12 | glibc 2.43 的内核底线查不到确切值 —— 不赌 |
| **`debian:12`** | **2.36** | **3.11** | ✅ 要求的内核远低于任何在用的目标机 |
| `debian:11` | 2.31 | **3.9** | ❌ 代码用了 `X \| None` 类型标注，**需要 3.10+** |

**真正把 Debian 11 排除掉的是 Python 版本**，不是内核 —— bullseye 只有 3.9。

pandoc 用官方**静态** arm64 二进制（精确钉在 3.7.0.2），**连 glibc 都不依赖**。

### 镜像体积（对磁盘紧张的部署机很重要）

| | 磁盘 | 传输包 |
|---|---|---|
| 初始版本 | 900 MB | 170 MB |
| 修正后 | **484 MB** | **95 MB** |

省下来的空间来自一处浪费：pandoc 的 tarball 里 `bin/pandoc`、`bin/pandoc-lua`、
`bin/pandoc-server` 是**同一个 165MB 二进制**（md5 完全相同），早先 `install .../bin/*`
把它拷了三份。现在只装 `pandoc`。

### 构建时的代理

构建要访问 GitHub（下 pandoc）和 PyPI。`compose` 里已经配好：

```yaml
build:
  network: host        # 让构建容器用宿主机网络栈
  args:
    HTTP_PROXY: ${BUILD_HTTP_PROXY:-http://127.0.0.1:7897}
```

目标机若能直连外网，把 `network: host` 和 `args` 那几行删掉即可。

**注意**：`dockerd` 自己拉镜像的代理是另一套配置，在
`/etc/systemd/system/docker.service.d/http-proxy.conf`。两处都配好才顺。

---

## 许可证

本项目以 **GPL-2.0-or-later** 发布，见 [`LICENSE`](LICENSE)。

它依赖并在 Docker 镜像里**再分发** pandoc（**GPL-2.0-or-later**），
第三方组件的版权、许可证与源码获取方式见 [`THIRD-PARTY.md`](THIRD-PARTY.md)。
镜像内也附了一份，位置是 `/usr/share/doc/pandoc-web/`，以及
`/usr/share/doc/pandoc/copyright`。

**关于商用**：GPL 不禁止收费，只要求「分发二进制时提供源码」。
**只提供网页服务**（用户拿不到二进制）时该义务不触发 —— 这也是本项目推荐的形态。
若要闭源分发，见 `THIRD-PARTY.md` 末尾的说明。

> 以上为工程判断，不构成法律意见。正式商用建议咨询专业人士。

---

## ⚠️ 安全须知

### markdown 的图片语法原本是「任意文件读 + SSRF」原语

pandoc 对图片引用**不做任何路径校验**。实测：

```
![x](/etc/hostname)          → 文件内容被原样嵌进 docx，退出码 0，零警告
![x](http://internal/secret) → 真的发起 HTTP 请求
![x](../../README.md)        → 相对穿越，同样读得到
```

在服务端这就是漏洞：上传者能把服务器文件下载走，也能探测内网。
`--resource-path` 挡不住绝对路径，`--sandbox` 在本发行版不可用 —— **pandoc 没有开关能关掉它**。

**本项目的对策**（filters/thesis_template.lua 里的资源校验 pass）：
默认拦截外部协议、绝对路径、UNC、相对穿越的图片；链接拦 `file://` 和本地路径
（那会把 SSRF 转嫁给打开文档的人）。拦截时替换成 alt 文本并告警。
本地转换自己的文档可以设 `THESIS_ALLOW_EXTERNAL_RESOURCES=1` 放行。

### 其他

- 服务端还额外设了 `http_proxy=http://127.0.0.1:1` 断掉子进程出网，作为纵深防御
- `-f markdown-raw_attribute` 禁掉了 `{=openxml}` —— 否则用户能往 `document.xml` 塞任意 OOXML
- 用户上传的 docx 模板在 `app/validate.py` 里做 zip 层面校验（炸弹、路径穿越、条目数）
- **容器里不要放任何秘密** —— 万一资源拦截被绕过，容器内文件是可读的
- 服务默认只绑 `127.0.0.1`。要对外提供必须先加鉴权，这是个吃内存的接口

---

## 已知问题

- **摘要过长会留白**：若「大标题 + 摘要 + 关键词」超过一页，关键词会溢到第 2 页，
  而第 1 章强制另起一页 → 第 2 页大面积留白。属于内容长度问题，压缩摘要即可。
- **列表项里的图片不加题注**：只有独立成段的图片才会居中并生成题注
  （`1. 说明\n    ![](a.png)` 这种写在列表项里的图只嵌入）。它们不是独立段落，
  硬拆出列表会改变文档结构，所以暂不处理。
- **图片按文件名匹配**：同名文件出现在两个目录时会报「重名，无法确定」并跳过 ——
  把文件名改成唯一即可。
- **加工后的模板自身** `document.xml` 里有指向已删图片的悬空引用 —— 无害，
  因为 pandoc 只用模板的 styles/settings，不用模板正文。

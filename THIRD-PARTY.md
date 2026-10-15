# 第三方组件与许可证

本项目自身以 **GPL-2.0-or-later** 发布（见 [`LICENSE`](LICENSE)）。
它依赖、并且在 **Docker 镜像里再分发** 下列第三方软件。这份文件说明它们的
版权归属、许可证，以及如何获取对应源码 —— 这是 GPL 对「再分发二进制」的要求。

---

## pandoc ⚠️ 需要特别说明

| | |
|---|---|
| 版本 | **3.7.0.2** |
| 版权 | Copyright (C) 2006-2024 John MacFarlane |
| 许可证 | **GPL-2.0-or-later**（部分文件 GPL-3.0-or-later） |
| 主页 | https://pandoc.org/ |
| **对应源码** | https://github.com/jgm/pandoc/releases/tag/3.7.0.2 |

我们分发的是 **pandoc 官方发布的、未经修改的静态二进制**
（`pandoc-3.7.0.2-linux-arm64.tar.gz`），安装到镜像的 `/usr/local/bin/pandoc`。

pandoc 是**独立进程**（本项目通过命令行调用它，没有链接进本项目代码），
所以 GPL 的 copyleft 不要求本项目代码也采用 GPL —— 但本项目主动选择了 GPL，
以彻底避开「Lua filter 是否属于衍生作品」这个定性争议。

> **为什么镜像里要手工放版权声明**：pandoc 是从官方 tarball 安装的，
> 不像 apt 安装会自动带上 `/usr/share/doc/pandoc/copyright`。
> 镜像里 `/usr/share/doc/pandoc-web/pandoc-copyright.txt` 是我们补的。

---

## Python 依赖

| 组件 | 许可证 | 版权 |
|---|---|---|
| [FastAPI](https://github.com/tiangolo/fastapi) | MIT | © 2018 Sebastián Ramírez |
| [Uvicorn](https://github.com/encode/uvicorn) | BSD-3-Clause | © 2017 Tom Christie |
| [python-multipart](https://github.com/Kludex/python-multipart) | Apache-2.0 | — |

它们的许可证全文随各自的发行包提供，可从上面链接的仓库获取。

---

## 基础镜像

镜像基于 **Debian GNU/Linux 12 (bookworm)**，其中包含大量遵循各自许可证的软件包
（多为 GPL / LGPL / MIT / BSD / Apache-2.0）。Debian 把这些许可证全文与版权信息
放在镜像内的 `/usr/share/doc/<包名>/copyright`，并汇总在
`/usr/share/common-licenses/`。

Debian 自身的版权信息见 https://www.debian.org/legal/licenses/

---

## 未使用但值得记录

早期版本曾考虑用 LibreOffice 做 `.doc → .docx` 转换，**现已移除**。
若将来重新引入，需注意：

- LibreOffice 是 **MPL-2.0 / LGPL-3.0-or-later** 双许可
- 它作为独立进程调用，同样不要求本项目代码改变许可证
- 但镜像体积会增加约 450 MB，需一并更新本文件

---

## 如果你要闭源

本项目选 GPL 主要是为了简单、无争议。若确实需要闭源分发：

1. **不要在镜像里打包 pandoc** —— 改成让用户自行安装，运行时不分发它
2. `filters/thesis_template.lua` 是本项目的核心逻辑，且运行在 pandoc 进程内 ——
   **这一点有定性争议，建议先咨询法律意见**，不要仅凭「只是调用命令行」就下结论
3. 只提供网页服务（用户拿不到二进制）则不受影响 ——
   GPL 的「分发」义务不会被触发（这也是 GPL 与 AGPL 的关键区别）

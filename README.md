# EasyTier 跨平台安装管理脚本

一个面向 Linux、OpenWrt / ImmortalWrt 等设备的 EasyTier 命令行安装与管理脚本。提供交互式菜单，帮助安装、更新和管理 EasyTier 核心，并可根据设备资源选择不同运行模式。

> **注意：** 当前脚本仍需在目标设备上进行实际安装和联网测试。运行前请先阅读脚本内容，并确认官方 Release 中存在与设备 CPU 架构匹配的安装包。请勿将未经验证的脚本直接用于重要生产设备。

## 功能

- 自动识别常见系统类型与 CPU 架构。
- 按 Gitee Release → 配置的 GitHub 镜像 → GitHub 官方 Release 的顺序下载核心组件。
- 提供三种运行模式：
  1. **核心 + 本地 Web 管理端**：在同一设备上运行核心和 Web 组件，资源占用相对较高。
  2. **仅核心 + 本地 TOML 配置**：只安装核心，适合闪存、内存较紧张的设备。
  3. **仅核心 + 远程 Web 控制台**：核心运行在轻量设备上，连接另一台设备上的远程配置服务。
- 管理服务启动、停止、重启和状态查看；本地配置文件模式在配置未填写前不会自动启动。
- 查看运行日志。
- 修改本地 Web 模式相关端口及 Web API 访问地址；其他模式提示在其配置位置修改。
- 编辑本地 TOML 配置文件，或设置远程配置服务地址。
- 更新 EasyTier 核心组件。
- 从配置的 GitHub 仓库更新本安装脚本，并在替换前执行 Shell 语法检查。
- 卸载组件；卸载时可选择保留或删除配置与数据。
- 支持常见的 `curl` 或 `wget` 下载工具，并在需要时尝试安装 `unzip`。

## 支持环境

脚本会尝试识别以下服务管理环境：

- OpenWrt / ImmortalWrt（`procd` / `/etc/init.d`）
- 使用 systemd 的 Linux
- OpenRC 环境
- 部分 SysV / BusyBox init 环境

脚本包含常见架构名称映射，例如 `x86_64`、`aarch64`、`armv7`、`armv6`、`i686`、`mips`、`mipsel`、`mips64el` 和 `riscv64`。**架构能被识别不代表官方一定提供对应的可运行二进制**；请以 EasyTier 官方 Release 的实际资产和设备 ABI 为准。

## 快速开始

```sh
curl -fsSL "https://raw.githubusercontent.com/jhbook/easytier-installer/refs/heads/main/easytier.sh" | sh
```
国内使用
```sh
curl -fsSL "https://cdn.jsdmirror.cn/gh/jhbook/easytier-installer@main/easytier.sh" | sh
```
脚本需要网络访问能力。根据下载和安装流程，系统通常需要 `curl` 或 `wget`、`unzip`，以及适合当前系统的服务管理工具。缺少 `unzip` 时脚本会尝试通过系统包管理器安装；如果自动安装失败，需要手动安装。

## 运行模式怎么选

| 模式 | 适用场景 | 说明 |
|---|---|---|
| 核心 + 本地 Web | 设备资源较充足，希望在本机管理 | 同时安装 `easytier-core` 与 `easytier-web-embed` |
| 仅核心 + 本地配置 | 低闪存、低内存设备，习惯手动维护配置 | 只运行核心，配置文件位于 `/opt/easytier/data/config.toml` |
| 仅核心 + 远程 Web | 轻量设备不适合运行 Web 组件 | 连接另一台设备提供的远程配置服务；需要填写正确的服务地址 |

本地 Web 模式的默认 Web/API 端口为 `11211`，配置服务 UDP 端口默认为 `22020`。请根据网络环境检查端口占用和防火墙规则，并避免将管理接口直接暴露到不可信网络。

## 常用目录

| 路径 | 用途 |
|---|---|
| `/opt/easytier/bin/` | EasyTier 核心和 Web 组件 |
| `/opt/easytier/data/` | 运行数据和本地配置文件 |
| `/etc/easytier-installer/settings` | 安装脚本保存的运行设置 |
| `/etc/easytier-installer/run.sh` | 部分环境下使用的运行脚本 |

具体文件是否存在取决于所选模式和当前系统。

## 下载源与镜像

菜单中的 **“下载源 / 镜像加速设置”** 可配置通用 GitHub 镜像前缀。EasyTier 核心安装包的下载顺序为：Gitee Release → 配置的通用镜像 → GitHub 官方 Release。获取最新版本号时优先请求 Gitee 的 `https://gitee.com/easytier/EasyTier/releases/latest`，通过重定向后的 `/releases/tag/版本号` 提取标签；如果 Gitee 页面无法解析，再尝试配置的 GitHub 镜像 API，最后尝试 GitHub 官方 API。 解析 Gitee 页面时会先保存到临时文件再提取版本号，避免异常响应中的 NUL 字节触发 Shell 命令替换警告。 下载 ZIP 后会单独尝试一次 Gitee 的 `.sha256` 文件；如果该文件不存在（404），会提示并跳过独立哈希校验，不会因此重新轮询其他安装包下载源。无论如何都会先执行 ZIP 完整性检查；若哈希文件存在且校验不匹配，则拒绝安装。

Gitee 最新 Release 入口：[https://gitee.com/easytier/EasyTier/releases/latest](https://gitee.com/easytier/EasyTier/releases/latest)。该地址会跳转到具体版本标签，例如：[v2.6.4](https://gitee.com/easytier/EasyTier/releases/tag/v2.6.4)。

镜像前缀应能代理脚本拼接出的完整 GitHub URL，例如：

```text
https://ghfast.top/
```

设置为 `official` 可清空自定义镜像。脚本优先尝试 Gitee Release 对应的版本与资产文件；Gitee 下载失败后，再尝试配置的通用镜像，最后回退到 GitHub 官方地址。Gitee 上的版本或资产可能与 GitHub 不完全同步；若 Gitee 下载失败，脚本会继续尝试 GitHub 官方源。某些镜像只支持下载 Release 文件，不支持 GitHub API，因此“镜像 API 测试失败”不一定代表 Release 文件下载也失败。

## 配置文件

仅核心 + 本地配置模式使用：

```text
/opt/easytier/data/config.toml
```

建议使用 [EasyTier 官方配置文档](https://easytier.cn/guide/network/config-file.html) 或官方配置助手生成适用于当前版本的 TOML 配置，再编辑文件。为了避免安装时先用空白占位配置启动，选择此模式后脚本只安装并写入服务，不会自动启动服务或启用开机自启。先编辑并保存 `config.toml`，然后回到菜单选择 **“启动服务”**；脚本会检查配置文件不是空白注释文件，再启动并启用开机自启。后续修改配置后，再使用“重启服务”使其生效。更新核心时，脚本会保留更新前的服务运行状态：原本停止的服务不会被自动启动。

## 服务与日志

可以在菜单中启动、停止、重启服务，或查看状态和日志。常见日志查看方式：

```sh
# systemd 环境
journalctl -u easytier -f

# OpenWrt / ImmortalWrt
logread -e easytier
```

实际服务管理方式取决于脚本识别到的系统环境。

## 服务与更新行为

- 更新核心前会记录服务是否正在运行；只有原本运行的服务才会在更新后重启，原本停止的服务继续保持停止。
- 启动或重启本地配置文件模式时，会先检查 `config.toml` 是否存在有效的非注释配置行；这只是基础检查，不能替代 EasyTier 自身的 TOML 解析验证。
- 服务停止时，运行包装脚本会清理核心和 Web 子进程，减少残留进程。
- 设置文件以安全引用方式写入，并通过临时文件替换，避免用户输入中的单引号破坏设置文件。
- 安装前会先验证所需的核心和 Web 二进制，再替换现有文件；仍建议在生产设备升级前备份配置。

## 安全提示

- 建议先在测试设备上运行，执行前检查脚本和下载来源。
- 请勿将 Web/API 管理端口暴露到公网；如需跨网访问，优先使用可信的 VPN、访问控制和防火墙策略。
- 远程 Web 模式必须填写正确的远程配置服务地址，并确保网络可达。
- 卸载时会先停止服务、禁用对应开机启动并清理常见残留启动链接；无论是否保留数据，都会删除运行包装脚本、运行环境文件和核心/Web 二进制，并清除已保存的本地 Web 端口设置。选择保留时，会保留 `/opt/easytier/data/` 与其他管理设置；Web 未安装时菜单显示“Web 端口：未配置”。选择删除时会进一步清除数据和全部管理设置。
- 脚本的 Shell 语法检查不等同于所有设备、架构和运行模式均已实测成功。

## 相关链接

- [EasyTier 官方 GitHub 仓库](https://github.com/EasyTier/EasyTier)
- [EasyTier 官方配置文档](https://easytier.cn/guide/network/config-file.html)

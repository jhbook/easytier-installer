# EasyTier 安装与管理脚本

面向 OpenWrt、ImmortalWrt 及常见 Linux 系统的 EasyTier 交互式安装管理工具。脚本负责下载和管理 EasyTier 核心组件、选择运行模式、配置服务启动方式，并提供后续更新与卸载菜单。

> 本项目是第三方安装管理脚本，不是 EasyTier 官方项目。请在运行前检查脚本内容，并先在测试设备验证。识别到 CPU 架构不代表 EasyTier 官方一定提供相应可用的 Release 资产。

## 快速开始

在目标设备的 root SSH 终端中执行：

```sh
curl -fsSL "https://raw.githubusercontent.com/jhbook/easytier-installer/refs/heads/main/easytier.sh" -o /tmp/easytier.sh && sh /tmp/easytier.sh
```

如果设备没有 `curl`，可以使用 `wget`：

```sh
wget -O /tmp/easytier.sh "https://raw.githubusercontent.com/jhbook/easytier-installer/refs/heads/main/easytier.sh" && sh /tmp/easytier.sh
```

#### 国内网络访问方式

如果设备访问 GitHub Raw 较慢或失败，可以尝试通过镜像下载管理脚本：

```sh
wget -O /tmp/easytier.sh "https://jsd.onmicrosoft.cn/gh/jhbook/easytier-installer@main/easytier.sh" && sh /tmp/easytier.sh
```

也可以使用 `curl`：

```sh
curl -fsSL "https://jsd.onmicrosoft.cn/gh/jhbook/easytier-installer@main/easytier.sh" -o /tmp/easytier.sh && sh /tmp/easytier.sh
```

镜像服务的可用性可能变化；若下载失败，请改用 GitHub 原始地址或其他可信镜像。注意，管理脚本下载地址与 EasyTier 核心下载源不同：安装器会优先尝试 Gitee 上的 EasyTier Release，再尝试配置的 GitHub 镜像，最后回退 GitHub 官方 Release。

首次以 root 运行时，脚本会尝试将管理脚本安装到 `/usr/bin/et`。安装成功后，之后输入以下命令即可打开菜单：

```sh
et
```

也支持在有可用控制终端的交互式 SSH 会话中使用管道启动：

```sh
curl -fsSL "https://raw.githubusercontent.com/jhbook/easytier-installer/refs/heads/main/easytier.sh" | sh
```

管道启动依赖可用的控制终端；在 cron、后台任务或无终端容器中不能使用交互菜单。为便于区分下载失败与运行失败，建议优先使用“下载到文件再执行”的方式。

## 功能一览

- 自动识别常见 Linux 系统、服务管理方式和 CPU 架构。
- 提供本地 Web、本地 TOML 配置、远程 Web 三种运行模式。
- 安装、更新 EasyTier 核心和当前模式需要的组件。
- 管理服务启动、停止、重启、状态和日志。
- 编辑本地 TOML 配置、设置远程 Web 配置服务器。
- 修改本地 Web 模式的端口与 Web API 地址。
- 设置下载镜像，并按多个来源尝试获取 EasyTier Release。
- 从指定 GitHub 仓库更新本管理脚本，替换前检查脚本身份和 Shell 语法。
- 卸载程序和服务，可选择保留或删除数据。

## 安装模式

| 模式 | 适用场景 | 说明 |
| --- | --- | --- |
| 核心 + 本地 Web 管理端 | 设备资源较充足，希望在本机使用 Web 管理 | 安装 EasyTier 核心和 Web 组件，资源占用相对较高 |
| 仅核心 + 本地 TOML 配置 | 低闪存设备或偏好手动编辑配置 | 只安装核心；编辑配置后再启动服务 |
| 仅核心 + 远程 Web 控制台 | 设备资源有限，希望由其他设备提供 Web 管理 | 本机运行核心，并连接远程配置服务 |

首次安装默认选择轻量的“仅核心 + 本地 TOML 配置”模式。需要在设备本机使用 Web 管理时，请在安装菜单中选择本地 Web 模式。

本地配置文件路径：

```text
/opt/easytier/data/config.toml
```

本地 Web 模式默认端口：

- Web/API 端口：`11211`
- 配置服务 UDP 端口：`22020`
- 节点端口默认值：`11010`

请根据实际网络环境检查端口占用和防火墙策略，不要把 Web/API 管理端口直接暴露给不可信网络。

## 菜单功能

| 选项 | 功能 |
| --- | --- |
| 1 | 安装 EasyTier，并选择运行模式 |
| 2 | 更新 EasyTier 核心/组件 |
| 3 | 更新安装管理脚本 |
| 4–6 | 启动、停止、重启服务 |
| 7 | 修改端口 / Web API 地址 |
| 8 | 编辑本地 TOML 配置文件 |
| 9 | 设置远程 Web 配置服务器 |
| 10 | 设置下载源 / 镜像加速 |
| 11–12 | 查看运行状态、日志 |
| 13 | 卸载全部 EasyTier：核心、服务、配置、数据库及管理脚本 `et`（仅确认一次） |
| 0 | 退出 |

在本地 TOML 配置模式下，安装完成后服务会保持停止状态，也不会自动启用开机启动。请先编辑并保存 `config.toml`，再从菜单选择“启动服务”。后续修改配置后，选择“重启服务”使其生效。

## 系统与依赖

脚本会尝试适配以下服务管理环境：

- OpenWrt / ImmortalWrt（procd）
- 使用 systemd 的 Linux
- OpenRC
- 部分 SysV / BusyBox init 环境

脚本使用 `curl` 或 `wget` 下载文件，并需要 `unzip` 解压 Release 压缩包。若缺少 `unzip`，脚本会尝试调用系统包管理器安装；自动安装失败时，需要手动安装依赖。安装组件和创建系统服务需要 root 权限。

脚本包含常见架构映射，例如 `x86_64`、`aarch64`、`armv7`、`armv6`、`i686`、`mips`、`mipsel`、`mips64el`、`riscv64`。最终是否有匹配的可用二进制，以 EasyTier 官方 Release 的实际资产和设备 ABI 为准。

## 下载源与镜像

菜单中的“下载源 / 镜像加速设置”可配置 GitHub 镜像前缀。核心 Release 下载按以下顺序尝试：

1. Gitee 上对应的 EasyTier Release 资产。
2. 配置的 GitHub 镜像。
3. GitHub 官方 Release。

获取最新版本信息时，脚本优先解析 Gitee 的 Release 页面；无法取得版本号时，再尝试 GitHub 镜像 API 和 GitHub 官方 API。下载后会检查 ZIP 完整性；如果获取到 SHA-256 校验文件，也会验证摘要。若 Gitee 上没有校验文件，会提示并跳过独立哈希校验，但仍会执行 ZIP 完整性检查。

默认镜像前缀为：

```text
https://github.chenc.dev/
```

镜像前缀需要能够代理脚本拼接出的完整 GitHub URL。也可以在菜单中选择官方源，清除自定义镜像。通用下载镜像通常只代理 Raw 文件或 Release 资产，不保证支持 GitHub API。因此菜单中的连通性测试只下载并校验安装脚本的 Raw 文件，不请求 GitHub API；核心下载仍会按配置的顺序逐源回退。选择官方源时，则测试 GitHub 官方 Raw 地址。

## 安装脚本自更新

脚本默认从以下仓库更新管理脚本：

```sh
SCRIPT_REPO="jhbook/easytier-installer"
SCRIPT_BRANCH="main"
SCRIPT_PATH="easytier.sh"
```

在菜单中选择“更新安装脚本”后，脚本会尝试使用已配置的镜像下载 Raw 文件；镜像下载失败或返回内容无效时，回退到 GitHub 官方 Raw 地址。替换前会检查文件非空、脚本标识和 `sh -n` 语法，并尝试备份旧文件为 `.bak`。 更新成功后会自动重新执行更新后的脚本，直接进入最新版菜单，无需退出再手动运行 `et`。

持久化管理脚本路径为：

```text
/usr/bin/et
```

如果该路径已存在且不像本项目脚本，为避免覆盖其他程序，首次安装不会强行替换它。此时请检查冲突文件，确认后再处理。

## 常用路径

| 路径 | 用途 |
| --- | --- |
| `/opt/easytier/bin/` | EasyTier 核心与 Web 组件 |
| `/opt/easytier/data/` | 本地配置与运行数据 |
| `/etc/easytier-installer/settings` | 安装管理脚本的设置 |
| `/etc/easytier-installer/run.sh` | 服务运行包装脚本 |
| `/usr/bin/et` | 持久化管理脚本入口 |

具体文件会随运行模式和系统类型变化，并非每台设备都会拥有表中全部文件。

## 服务与日志

可以直接在管理菜单中启动、停止、重启服务，查看运行状态和日志。也可根据系统使用相应日志工具，例如：

```sh
# systemd 系统
journalctl -u easytier -f

# OpenWrt / ImmortalWrt
logread -e easytier
```

实际服务名称和日志位置可能随系统环境而异。

## 卸载说明

卸载时脚本会先停止服务并尝试禁用开机启动，再清理服务入口和核心/Web 二进制。随后可以选择：

- **保留数据**：保留 EasyTier 本地数据和组网配置，同时清除已卸载 Web 组件对应的端口设置；保留 `et` 管理命令，方便后续重新安装或管理。
- **删除数据**：进一步删除配置、数据库和管理设置，并尝试移除本项目安装的 `/usr/bin/et` 命令。

卸载前请确认是否仍需要 `config.toml`、数据库和其他运行数据。建议先备份重要配置。

## 故障排查

- **提示缺少下载工具**：安装 `curl` 或 `wget` 后重试。
- **提示缺少 `unzip`**：手动安装 `unzip`，再运行安装菜单。
- **下载失败**：在菜单中更换镜像或切换到官方源；确认设备能访问相应站点。
- **菜单直接退出**：确认是在交互式 SSH/终端中运行，并使用“下载到文件再执行”的命令。
- **本地配置模式无法启动**：检查 `/opt/easytier/data/config.toml` 是否已填写有效配置；基础检查不等于完整 TOML 语法验证。
- **没有匹配的 Release 资产**：确认设备 CPU 架构、ABI 与 EasyTier 官方发布的二进制相符。
- **`et` 命令不存在**：确认首次运行有 root 权限，且 `/usr/bin` 位于 `PATH`；也可以运行 `/usr/bin/et`。

## 安全与测试说明

- EasyTier 的网络名称、密钥和配置应妥善保管，不要公开包含敏感信息的配置文件。
- 不要将 Web/API 管理接口暴露到公网；跨网管理应配合可信组网、访问控制和防火墙。
- 执行脚本前请审查来源和内容；生产设备升级前先备份配置。
- Shell 语法检查和压缩包完整性检查不代表已在所有设备上完成实测。请先在测试设备验证安装、启动、联网、更新与卸载流程。

## 相关链接

- [EasyTier 官方 GitHub 仓库](https://github.com/EasyTier/EasyTier)
- [EasyTier 官方文档](https://easytier.cn/)
- [EasyTier 配置文件文档](https://easytier.cn/guide/network/config-file.html)

### 安装脚本自更新失败

菜单会显示当前安装脚本版本号。菜单 3 更新安装脚本时，按以下顺序尝试并在每一步检查脚本身份与 Shell 语法：

1. jsDelivr 镜像：`https://jsd.onmicrosoft.cn/gh/jhbook/easytier-installer@main/easytier.sh`
2. 菜单中配置的通用 GitHub 镜像（如果已配置）。
3. GitHub 官方 Raw：`https://raw.githubusercontent.com/jhbook/easytier-installer/main/easytier.sh`。

前一个来源下载失败或校验不通过时才会继续尝试下一个来源。下载地址不追加时间戳查询参数，以兼容不支持额外查询参数的镜像/CDN；脚本通过校验下载内容来判断是否可用。

## 版本说明（v0.4.3）

- 主菜单新增 EasyTier 安装目录占用大小显示，统计 `/opt/easytier` 整个目录，包含目录内的核心、Web 组件、配置、数据库及运行数据；未创建目录时显示“0B（未安装）”。

## 版本说明（v0.4.2）

- 菜单 13 改为直接卸载全部 EasyTier，不再进入卸载方式二级菜单。
- 确认后删除 EasyTier 核心、服务、配置、数据库及 `et` 管理脚本；取消确认则返回主菜单。
- 移除仅卸载管理脚本的独立流程及“是否保留配置/数据库”的二次选择。


- 修复菜单 10 的镜像检测逻辑：使用实际 Raw 安装脚本下载及内容校验判断连通性。
- 优先测试安装脚本实际使用的 Raw 下载路径，并校验返回内容确实是本项目安装脚本。
- 删除菜单 10 中的 GitHub API 连通性检测，只保留实际 Raw 安装脚本下载及内容校验。
- 菜单输入错误时提示有效范围并等待用户确认，然后返回菜单，不会因输入错误直接退出。
- 菜单读取输入失败时提示后重试，不直接退出管理程序。
- 菜单操作中的可恢复错误（例如未安装核心就选择更新）不会关闭整个管理程序；错误提示后按回车即可返回主菜单。
- 安装、核心更新、服务操作、端口设置、配置编辑和下载设置等操作在独立子 Shell 中运行，避免内部错误处理意外终止菜单。
- 安装脚本自更新失败时返回菜单；更新成功后仍自动进入新版菜单。


### v0.3.9

- 合并原菜单 13 和菜单 14，主菜单只保留一个卸载入口。
- 更新主菜单选项范围为 0–13。


### v0.4.2

- 删除所有下载链接中用于防缓存的时间戳查询参数（`?_=`），避免部分镜像/CDN 不支持额外参数导致下载失败。
- 菜单 10 镜像连通性测试、脚本自更新及首次启动引导统一使用原始 URL。

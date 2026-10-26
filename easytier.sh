#!/bin/sh
# EasyTier cross-platform installer/manager
# Supports OpenWrt/ImmortalWrt (procd), systemd, OpenRC and SysV/BusyBox init.
# Supports local Web, local TOML config, and remote Web control modes.
# Copyright (c) OpenAI. Review before running on production systems.

set -u

APP="easytier"
REPO="EasyTier/EasyTier"
# The self-updater fetches SCRIPT_PATH from SCRIPT_BRANCH on this repository.
SCRIPT_REPO="jhbook/easytier-installer"
SCRIPT_BRANCH="main"
SCRIPT_PATH="easytier.sh"
SCRIPT_VERSION="0.4.4"
BASE="/opt/easytier"
BIN="$BASE/bin"
DATA="$BASE/data"
CONF="/etc/easytier-installer"
SETTINGS="$CONF/settings"
CORE="$BIN/easytier-core"
WEB="$BIN/easytier-web-embed"
SERVICE_NAME="easytier"
DEFAULT_WEB_PORT="11211"
DEFAULT_CONFIG_PORT="22020"
DEFAULT_NODE_PORT="11010"
DEFAULT_USER="easytier"
DEFAULT_MODE="config-file"
DEFAULT_REMOTE_URL=""
DEFAULT_MIRROR="https://github.chenc.dev/"
TMPDIR_ET=""

# ---------- helpers ----------
cleanup_temp() {
  if [ -n "${TMPDIR_ET:-}" ] && [ -d "$TMPDIR_ET" ]; then rm -rf "$TMPDIR_ET"; fi
}
trap 'cleanup_temp' EXIT
say()  { printf '%s\n' "$*"; }
info() { printf '[信息] %s\n' "$*"; }
warn() { printf '[提示] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# Always read menu input from the controlling terminal when one exists. This lets
# interactive mode work even when the script itself was supplied through a pipe.
read() {
  if [ -t 0 ]; then command read "$@"
  elif ( : </dev/tty ) 2>/dev/null; then command read "$@" </dev/tty
  else command read "$@"
  fi
}
pause() { printf '\n按回车键继续...'; read -r _dummy || :; }
# Report the complete EasyTier installation directory footprint, including
# binaries, configuration, databases and runtime data where stored under BASE.
easytier_dir_size() {
  if [ -d "$BASE" ]; then
    size="$(du -sh "$BASE" 2>/dev/null | awk 'NR == 1 {print $1}')"
    [ -n "$size" ] && printf '%s' "$size" || printf '未知'
  else
    printf '0B（未安装）'
  fi
}
is_root() { [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; }
valid_port() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; }
mkdir_p() { mkdir -p "$1" 2>/dev/null || die "无法创建目录：$1"; }
url_encode_slashless() { printf '%s' "$1" | sed 's/ /%20/g'; }

load_settings() {
  WEB_PORT="$DEFAULT_WEB_PORT"
  CONFIG_PORT="$DEFAULT_CONFIG_PORT"
  NODE_PORT="$DEFAULT_NODE_PORT"
  API_HOST=""
  USERNAME="$DEFAULT_USER"
  RUN_MODE="$DEFAULT_MODE"
  REMOTE_URL="$DEFAULT_REMOTE_URL"
  MIRROR="$DEFAULT_MIRROR"
  VERSION="latest"
  [ -f "$SETTINGS" ] && . "$SETTINGS"
  # Avoid empty values from old/malformed settings.
  : "${WEB_PORT:=$DEFAULT_WEB_PORT}"
  : "${CONFIG_PORT:=$DEFAULT_CONFIG_PORT}"
  : "${NODE_PORT:=$DEFAULT_NODE_PORT}"
  : "${USERNAME:=$DEFAULT_USER}"
  : "${RUN_MODE:=$DEFAULT_MODE}"
  : "${REMOTE_URL:=$DEFAULT_REMOTE_URL}"
  : "${MIRROR:=$DEFAULT_MIRROR}"
  : "${VERSION:=latest}"
  # Older installs may have stored port 0 after switching away from local Web.
  # Restore sensible defaults when local Web mode is selected again.
  if [ "$RUN_MODE" = "local-web" ]; then
    valid_port "$WEB_PORT" || WEB_PORT="$DEFAULT_WEB_PORT"
    valid_port "$CONFIG_PORT" || CONFIG_PORT="$DEFAULT_CONFIG_PORT"
    valid_port "$NODE_PORT" || NODE_PORT="$DEFAULT_NODE_PORT"
  fi
  if [ -z "${API_HOST:-}" ]; then API_HOST="$(detect_lan_ip)"; fi
}
shell_quote() {
  # Return a safely single-quoted shell value for the settings file.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
save_settings() {
  mkdir_p "$CONF"
  umask 077
  settings_tmp="$SETTINGS.tmp.$$"
  {
    printf 'WEB_PORT=%s\n' "$(shell_quote "$WEB_PORT")"
    printf 'CONFIG_PORT=%s\n' "$(shell_quote "$CONFIG_PORT")"
    printf 'NODE_PORT=%s\n' "$(shell_quote "$NODE_PORT")"
    printf 'API_HOST=%s\n' "$(shell_quote "$API_HOST")"
    printf 'USERNAME=%s\n' "$(shell_quote "$USERNAME")"
    printf 'RUN_MODE=%s\n' "$(shell_quote "$RUN_MODE")"
    printf 'REMOTE_URL=%s\n' "$(shell_quote "$REMOTE_URL")"
    printf 'MIRROR=%s\n' "$(shell_quote "$MIRROR")"
    printf 'VERSION=%s\n' "$(shell_quote "$VERSION")"
  } > "$settings_tmp" || { rm -f "$settings_tmp"; die "写入设置文件失败。"; }
  chmod 600 "$settings_tmp" 2>/dev/null || :
  mv "$settings_tmp" "$SETTINGS" || { rm -f "$settings_tmp"; die "保存设置文件失败。"; }
  chmod 600 "$SETTINGS" 2>/dev/null || :
}
detect_lan_ip() {
  # Prefer the configured LAN address on OpenWrt. `ip route get 1.1.1.1`
  # often returns the WAN source address, which makes the displayed Web URL
  # unreachable from LAN clients and also breaks the frontend's API endpoint.
  if have uci; then
    lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null | head -n 1)"
    case "$lan_ip" in
      ''|0.0.0.0|127.*) ;;
      *.*.*.*) printf '%s\n' "$lan_ip"; return 0 ;;
    esac
  fi
  # On other Linux systems, prefer a private IPv4 address assigned locally.
  if have ip; then
    lan_ip="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); if (a[1] ~ /^10\./ || a[1] ~ /^192\.168\./ || a[1] ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) {print a[1]; exit}}')"
    [ -n "$lan_ip" ] && { printf '%s\n' "$lan_ip"; return 0; }
    ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1
  fi
}
detect_os() {
  if [ -f /etc/openwrt_release ] || grep -qi 'openwrt\|immortalwrt' /etc/os-release 2>/dev/null; then
    echo openwrt
  elif [ -f /etc/alpine-release ]; then
    echo openrc
  elif have systemctl && [ -d /run/systemd/system ]; then
    echo systemd
  elif [ -d /etc/init.d ] && have rc-service; then
    echo openrc
  elif [ -d /etc/init.d ]; then
    echo sysv
  else
    echo manual
  fi
}
detect_arch() {
  m="$(uname -m 2>/dev/null || echo unknown)"
  case "$m" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    armv7l|armv7*) echo armv7 ;;
    armv6l|armv6*) echo armv6 ;;
    i386|i486|i586|i686) echo i686 ;;
    mipsel|mipsle) echo mipsel ;;
    mips) echo mips ;;
    mips64el) echo mips64el ;;
    riscv64) echo riscv64 ;;
    *) echo "$m" ;;
  esac
}
download_tool() {
  if have curl; then DL_TOOL=curl
  elif have wget; then DL_TOOL=wget
  else DL_TOOL=none
  fi
}
download_file() {
  url="$1"; out="$2"
  case "$DL_TOOL" in
    curl) curl -fL --connect-timeout 12 --max-time 600 --retry 1 --retry-delay 1 "$url" -o "$out" ;;
    wget) wget -T 20 -t 2 -O "$out" "$url" ;;
    *) return 127 ;;
  esac
}
valid_installer_script() {
  candidate="$1"
  [ -s "$candidate" ] || return 1
  sh -n "$candidate" >/dev/null 2>&1 || return 1
  grep -q 'EasyTier 跨平台安装管理工具\|EasyTier cross-platform installer' "$candidate" 2>/dev/null
}
fetch_text() {
  url="$1"
  case "$DL_TOOL" in
    curl) curl -fsSL --connect-timeout 8 --max-time 25 "$url" 2>/dev/null ;;
    wget) wget -T 10 -t 1 -qO- "$url" 2>/dev/null ;;
    *) return 1 ;;
  esac
}
need_root() { is_root || die "请使用 root 运行：sudo sh $0"; }
ensure_tools() {
  download_tool
  [ "$DL_TOOL" != none ] || die "缺少 curl/wget，请先安装其中一个。"
  if ! have unzip; then
    warn "缺少 unzip。尝试通过系统包管理器安装..."
    if have opkg; then opkg update >/dev/null 2>&1; opkg install unzip >/dev/null 2>&1
    elif have apk; then apk add unzip >/dev/null 2>&1
    elif have apt-get; then apt-get update >/dev/null 2>&1 && apt-get install -y unzip >/dev/null 2>&1
    elif have dnf; then dnf install -y unzip >/dev/null 2>&1
    elif have yum; then yum install -y unzip >/dev/null 2>&1
    fi
  fi
  have unzip || die "需要 unzip 才能解压官方 ZIP。请手动安装 unzip 后重试。"
}
latest_version() {
  # Prefer Gitee's latest-release redirect; it resolves to /releases/tag/<version>.
  # Example: https://gitee.com/easytier/EasyTier/releases/latest -> .../releases/tag/v2.6.4
  v=""
  latest_url="https://gitee.com/easytier/EasyTier/releases/latest"
  if [ "$DL_TOOL" = curl ]; then
    final_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 8 --max-time 25 "$latest_url" 2>/dev/null || :)"
    case "$final_url" in
      https://gitee.com/easytier/EasyTier/releases/tag/*)
        v="${final_url##*/}"
        v="${v%%\?*}"
        v="${v%%\#*}"
        ;;
    esac
  fi
  # wget follows redirects but does not expose the final URL consistently; parse the
  # canonical release URL from a temporary file. Do not put the whole HTML response
  # in command substitution: unexpected NUL bytes in a response trigger shell warnings.
  if [ -z "$v" ]; then
    page_file="$(mktemp "${TMPDIR:-/tmp}/easytier-gitee-latest.XXXXXX" 2>/dev/null || :)"
    [ -n "$page_file" ] || page_file="${TMPDIR:-/tmp}/easytier-gitee-latest.$$"
    rm -f "$page_file"
    case "$DL_TOOL" in
      curl) curl -fsSL --connect-timeout 8 --max-time 25 "$latest_url" -o "$page_file" 2>/dev/null || : ;;
      wget) wget -T 10 -t 1 -qO "$page_file" "$latest_url" 2>/dev/null || : ;;
    esac
    if [ -s "$page_file" ]; then
      v="$(grep -aoE 'https://gitee\.com/easytier/EasyTier/releases/tag/[vV]?[0-9][A-Za-z0-9._-]*' "$page_file" 2>/dev/null | head -n 1 | sed 's#.*/##')"
    fi
    rm -f "$page_file"
  fi
  # Validate the result before using it in asset URLs.
  case "$v" in
    v[0-9]*|[0-9]*)
      case "$v" in *[!A-Za-z0-9._+-]*) v="";; esac
      ;;
    *) v="" ;;
  esac
  [ -n "$v" ] || {
    # If Gitee's latest redirect is unavailable, try GitHub's API through the
    # configured mirror, then the official API.
    api="https://api.github.com/repos/$REPO/releases/latest"
    if [ -n "${MIRROR:-}" ]; then
      mirror_api="${MIRROR%/}/https://api.github.com/repos/$REPO/releases/latest"
      v="$(fetch_text "$mirror_api" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    fi
    [ -n "$v" ] || v="$(fetch_text "$api" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  }
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}
asset_url() {
  # Asset pattern used by the official EasyTier release installer.
  arch="$1"; ver="$2"
  printf 'https://github.com/%s/releases/download/%s/easytier-linux-%s-%s.zip' "$REPO" "$ver" "$arch" "$ver"
}
mirror_url() {
  original="$1"
  if [ -n "${MIRROR:-}" ]; then printf '%s/%s' "${MIRROR%/}" "$original"
  else printf '%s' "$original"
  fi
}
download_with_fallback() {
  original="$1"; output="$2"
  rm -f "$output"
  # Try the Gitee EasyTier release mirror first.
  case "$original" in
    https://github.com/EasyTier/EasyTier/releases/download/*)
      gitee_url="$(printf '%s' "$original" | sed 's#^https://github.com/EasyTier/EasyTier/releases/download/#https://gitee.com/easytier/EasyTier/releases/download/#')"
      info "优先尝试 Gitee Release 源：$gitee_url"
      if download_file "$gitee_url" "$output" && [ -s "$output" ] && unzip -t "$output" >/dev/null 2>&1; then return 0; fi
      warn "Gitee Release 下载失败或 ZIP 无效，尝试配置的 GitHub 镜像。"
      rm -f "$output"
      ;;
  esac
  if [ -n "${MIRROR:-}" ]; then
    u="$(mirror_url "$original")"
    info "尝试配置的 GitHub 镜像源：$u"
    if download_file "$u" "$output" && [ -s "$output" ] && unzip -t "$output" >/dev/null 2>&1; then return 0; fi
    warn "配置的镜像下载失败或 ZIP 无效，回退 GitHub 官方源。"
    rm -f "$output"
  fi
  info "尝试 GitHub 官方源：$original"
  if download_file "$original" "$output" && [ -s "$output" ] && unzip -t "$output" >/dev/null 2>&1; then return 0; fi
  rm -f "$output"
  warn "GitHub 官方源下载失败或 ZIP 无效。"
  return 1
}
check_checksum_if_available() {
  # Check the matching Gitee checksum once only. A missing checksum must not
  # trigger the full asset-source fallback chain after the ZIP already downloaded.
  zipfile="$1"; ver="$2"; arch="$3"
  sum_url="https://gitee.com/easytier/EasyTier/releases/download/$ver/easytier-linux-$arch-$ver.zip.sha256"
  sumfile="$TMPDIR_ET/checksum"
  rm -f "$sumfile"
  if ! download_file "$sum_url" "$sumfile" >/dev/null 2>&1 || [ ! -s "$sumfile" ]; then
    rm -f "$sumfile"
    warn "Gitee 未提供独立 SHA-256 文件，跳过哈希校验；继续进行 ZIP 完整性检查。"
    return 0
  fi
  expected="$(awk 'NR==1 {print $1}' "$sumfile" | tr 'A-F' 'a-f')"
  case "$expected" in
    ''|*[!0-9a-f]*) warn "SHA-256 文件格式无效，拒绝安装。"; return 1 ;;
  esac
  [ "${#expected}" -eq 64 ] || { warn "SHA-256 长度无效，拒绝安装。"; return 1; }
  if have sha256sum; then actual="$(sha256sum "$zipfile" | awk '{print $1}')"
  elif have shasum; then actual="$(shasum -a 256 "$zipfile" | awk '{print $1}')"
  else warn "存在 SHA-256 文件但系统没有 sha256sum/shasum，跳过哈希校验。"; return 0
  fi
  [ "$expected" = "$actual" ] || return 1
  info "SHA-256 校验通过。"
  return 0
}

get_asset_and_extract() {
  arch="$(detect_arch)"
  case "$arch" in
    x86_64|aarch64|armv7|armv6|i686|mipsel|mips|mips64el|riscv64) ;;
    *) die "暂未识别架构：$arch。不会下载不匹配的二进制。可在 EasyTier 官方 Release 确认支持情况后扩展映射。" ;;
  esac
  info "检测到架构：$arch"
  [ "$VERSION" != latest ] || VERSION="$(latest_version)" || die "无法获取最新版本号。请检查 Gitee latest Release 页面是否可访问，或在下载源设置中配置可用镜像。"
  info "准备下载 EasyTier 版本：$VERSION"
  if have mktemp; then
    TMPDIR_ET="$(mktemp -d "${TMPDIR:-/tmp}/easytier-install.XXXXXX")" || die "无法创建临时目录；可设置 TMPDIR 指向有足够空间的可写目录。"
  else
    TMPDIR_ET="${TMPDIR:-/tmp}/easytier-install.$$"
    (umask 077 && mkdir "$TMPDIR_ET") 2>/dev/null || die "无法创建临时目录；可设置 TMPDIR 指向有足够空间的可写目录。"
  fi
  zip="$TMPDIR_ET/easytier.zip"
  url="$(asset_url "$arch" "$VERSION")"
  download_with_fallback "$url" "$zip" || die "下载失败：$url"
  unzip -t "$zip" >/dev/null 2>&1 || die "ZIP 文件校验失败，拒绝安装。"
  check_checksum_if_available "$zip" "$VERSION" "$arch" || die "SHA-256 不匹配，拒绝安装。"
  mkdir_p "$TMPDIR_ET/unpack"
  unzip -oq "$zip" -d "$TMPDIR_ET/unpack" || die "解压失败。"
  # Official release ZIP normally contains easytier-linux-ARCH/easytier-core and easytier-web-embed.
  core_found="$(find "$TMPDIR_ET/unpack" -type f -name easytier-core 2>/dev/null | head -n 1)"
  web_found="$(find "$TMPDIR_ET/unpack" -type f -name easytier-web-embed 2>/dev/null | head -n 1)"
  [ -n "$core_found" ] || die "压缩包中没有 easytier-core，可能是架构不受支持或资产命名已变化。"
  mkdir_p "$BIN"
  # Stage and validate every required binary before replacing any installed file.
  cp "$core_found" "$CORE.new" || die "复制核心二进制失败。"
  chmod 755 "$CORE.new"
  "$CORE.new" --version >/dev/null 2>&1 || { rm -f "$CORE.new"; die "easytier-core 无法运行，可能是 CPU/ABI 不兼容。"; }
  if [ "$RUN_MODE" = "local-web" ]; then
    [ -n "$web_found" ] || { rm -f "$CORE.new"; die "当前选择本地 Web 模式，但压缩包中没有 easytier-web-embed。"; }
    cp "$web_found" "$WEB.new" || { rm -f "$CORE.new" "$WEB.new"; die "复制 Web 二进制失败。"; }
    chmod 755 "$WEB.new"
    "$WEB.new" --help >/dev/null 2>&1 || { rm -f "$CORE.new" "$WEB.new"; die "easytier-web-embed 无法运行，可能是 CPU/ABI 不兼容。"; }
  fi
  old_core="$BIN/easytier-core.old.$$"
  old_web="$BIN/easytier-web-embed.old.$$"
  had_core=no; had_web=no
  if [ -f "$CORE" ]; then mv "$CORE" "$old_core" || die "无法暂存旧核心，未替换现有安装。"; had_core=yes; fi
  if [ "$RUN_MODE" = "local-web" ] && [ -f "$WEB" ]; then
    if ! mv "$WEB" "$old_web"; then
      [ "$had_core" = yes ] && mv "$old_core" "$CORE" 2>/dev/null || :
      die "无法暂存旧 Web 组件，未完成更新。"
    fi
    had_web=yes
  fi
  if ! mv "$CORE.new" "$CORE"; then
    [ "$had_core" = yes ] && mv "$old_core" "$CORE" 2>/dev/null || :
    [ "$had_web" = yes ] && mv "$old_web" "$WEB" 2>/dev/null || :
    die "替换 EasyTier 核心失败，已尝试恢复旧版本。"
  fi
  if [ "$RUN_MODE" = "local-web" ]; then
    if ! mv "$WEB.new" "$WEB"; then
      rm -f "$CORE"
      [ "$had_core" = yes ] && mv "$old_core" "$CORE" 2>/dev/null || :
      [ "$had_web" = yes ] && mv "$old_web" "$WEB" 2>/dev/null || :
      die "替换 Web 二进制失败，已尝试恢复旧版本。"
    fi
  else
    rm -f "$WEB"
  fi
  rm -f "$old_core" "$old_web"
  rm -rf "$TMPDIR_ET"
  TMPDIR_ET=""
  info "核心与 Web 二进制安装完成。"
}
make_config() {
  mkdir_p "$DATA"
  mkdir_p "$CONF"
  case "$RUN_MODE" in
    local-web)
      cat > "$DATA/core.args" <<EOF
--config-server
udp://127.0.0.1:${CONFIG_PORT}/${USERNAME}
EOF
      ;;
    config-file)
      if [ ! -f "$DATA/config.toml" ]; then
        cat > "$DATA/config.toml" <<'EOF'
# EasyTier 本地配置文件（TOML）
# 请使用 EasyTier 官方配置助手生成配置后粘贴到此文件，或按对应版本配置文档编辑。
# 官方配置文档：https://easytier.cn/guide/network/config-file.html
# 注意：不要把 TOML 配置直接写入 core.args；本模式通过 -c 加载此文件。
EOF
      fi
      ;;
    remote-web)
      [ -n "$REMOTE_URL" ] || die "远程 Web 控制地址不能为空。"
      ;;
    *) die "未知运行模式：$RUN_MODE" ;;
  esac
  chmod 600 "$DATA/core.args" "$DATA/config.toml" 2>/dev/null || :
  save_settings
}

write_runtime_env() {
  # Used by service scripts. Keep the web API host reachable from other LAN devices.
  [ -n "${API_HOST:-}" ] || API_HOST="$(detect_lan_ip)"
  [ -n "${API_HOST:-}" ] || API_HOST="127.0.0.1"
  env_tmp="$CONF/runtime.env.tmp.$$"
  umask 077
  {
    printf 'BASE=%s\n' "$(shell_quote "$BASE")"
    printf 'BIN=%s\n' "$(shell_quote "$BIN")"
    printf 'DATA=%s\n' "$(shell_quote "$DATA")"
    printf 'CORE=%s\n' "$(shell_quote "$CORE")"
    printf 'WEB=%s\n' "$(shell_quote "$WEB")"
    printf 'RUN_MODE=%s\n' "$(shell_quote "$RUN_MODE")"
    printf 'REMOTE_URL=%s\n' "$(shell_quote "$REMOTE_URL")"
    printf 'WEB_PORT=%s\n' "$(shell_quote "$WEB_PORT")"
    printf 'CONFIG_PORT=%s\n' "$(shell_quote "$CONFIG_PORT")"
    printf 'NODE_PORT=%s\n' "$(shell_quote "$NODE_PORT")"
    printf 'API_HOST=%s\n' "$(shell_quote "$API_HOST")"
    printf 'USERNAME=%s\n' "$(shell_quote "$USERNAME")"
  } > "$env_tmp" || { rm -f "$env_tmp"; die "写入运行环境文件失败。"; }
  chmod 600 "$env_tmp" 2>/dev/null || :
  mv "$env_tmp" "$CONF/runtime.env" || { rm -f "$env_tmp"; die "更新运行环境文件失败。"; }
  chmod 600 "$CONF/runtime.env" 2>/dev/null || :
}
write_systemd() {
  cat > /etc/systemd/system/easytier.service <<'EOF'
[Unit]
Description=EasyTier Core and Embedded Web
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/easytier-installer/runtime.env
ExecStart=/etc/easytier-installer/run.sh
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || :
  systemctl enable easytier.service >/dev/null 2>&1 || :
}

write_openwrt() {
  cat > /etc/init.d/easytier <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service() {
  procd_open_instance
  procd_set_param command /etc/easytier-installer/run.sh
  procd_set_param respawn 3600 5 5
  procd_set_param file /etc/easytier-installer/runtime.env /opt/easytier/data/core.args /opt/easytier/data/config.toml
  procd_close_instance
}
EOF
  chmod 755 /etc/init.d/easytier
  /etc/init.d/easytier enable >/dev/null 2>&1 || :
}

write_openrc() {
  cat > /etc/init.d/easytier <<'EOF'
#!/sbin/openrc-run
description="EasyTier core and embedded Web"
command="/bin/sh"
command_args="/etc/easytier-installer/run.sh"
command_background="yes"
pidfile="/run/easytier.pid"
directory="/opt/easytier/data"
depend() { need net; after firewall; }
EOF
  chmod 755 /etc/init.d/easytier
  rc-update add easytier default >/dev/null 2>&1 || :
}
write_sysv() {
  cat > /etc/init.d/easytier <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides: easytier
# Required-Start: $network
# Required-Stop: $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
### END INIT INFO
case "${1:-}" in
  start) /etc/easytier-installer/run.sh >/dev/null 2>&1 & echo $! > /run/easytier-wrapper.pid ;;
  stop) [ -f /run/easytier-wrapper.pid ] && kill "$(cat /run/easytier-wrapper.pid)" 2>/dev/null; rm -f /run/easytier-wrapper.pid ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
EOF
  chmod 755 /etc/init.d/easytier
  if have update-rc.d; then update-rc.d easytier defaults >/dev/null 2>&1 || :
  elif have rc-update; then rc-update add easytier default >/dev/null 2>&1 || :; fi
}
write_runner() {
  cat > "$CONF/run.sh" <<'EOF'
#!/bin/sh
. /etc/easytier-installer/runtime.env
cd "$DATA" || exit 1
WEB_PID=""
CORE_PID=""
cleanup() {
  if [ -n "$CORE_PID" ]; then kill "$CORE_PID" 2>/dev/null || :; fi
  if [ -n "$WEB_PID" ]; then kill "$WEB_PID" 2>/dev/null || :; fi
  [ -z "$CORE_PID" ] || wait "$CORE_PID" 2>/dev/null || :
  [ -z "$WEB_PID" ] || wait "$WEB_PID" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
case "$RUN_MODE" in
  local-web)
    "$WEB" --api-server-addr 0.0.0.0 --web-server-addr 0.0.0.0 --api-server-port "$WEB_PORT" --api-host "http://${API_HOST}:${WEB_PORT}" --config-server-port "$CONFIG_PORT" --config-server-protocol udp &
    WEB_PID=$!
    sleep 2
    "$CORE" --config-server "udp://127.0.0.1:${CONFIG_PORT}/${USERNAME}" --listeners "$NODE_PORT" &
    CORE_PID=$!
    ;;
  config-file)
    [ -f "$DATA/config.toml" ] || { echo "缺少配置文件：$DATA/config.toml" >&2; exit 1; }
    "$CORE" -c "$DATA/config.toml" &
    CORE_PID=$!
    ;;
  remote-web)
    [ -n "$REMOTE_URL" ] || { echo "未设置远程 Web 配置服务器地址" >&2; exit 1; }
    "$CORE" -w "$REMOTE_URL" &
    CORE_PID=$!
    ;;
  *) echo "未知运行模式：$RUN_MODE" >&2; exit 1 ;;
esac
wait "$CORE_PID"
rc=$?
cleanup
trap - EXIT HUP INT TERM
exit "$rc"
EOF
  chmod 700 "$CONF/run.sh"
}

validate_start_config() {
  [ "$RUN_MODE" = "config-file" ] || return 0
  config_file="$DATA/config.toml"
  [ -s "$config_file" ] || { warn "本地配置文件不存在或为空：$config_file。请先填写配置，再启动服务。"; return 1; }
  if ! grep -Eq '^[[:space:]]*[^#[:space:]][^=]*=' "$config_file"; then
    warn "本地配置文件目前只有空行/注释：$config_file。请先粘贴有效 TOML 配置，再启动服务。"
    return 1
  fi
}
service_is_active() {
  os="$(detect_os)"
  case "$os" in
    systemd) systemctl is-active --quiet easytier.service ;;
    openwrt) /etc/init.d/easytier status >/dev/null 2>&1 || { have pidof && pidof easytier-core >/dev/null 2>&1; } ;;
    openrc) rc-service easytier status >/dev/null 2>&1 || { have pidof && pidof easytier-core >/dev/null 2>&1; } ;;
    sysv) [ -f /run/easytier-wrapper.pid ] && kill -0 "$(cat /run/easytier-wrapper.pid 2>/dev/null)" 2>/dev/null || { have pidof && pidof easytier-core >/dev/null 2>&1; } ;;
    *) return 1 ;;
  esac
}
install_service() {
  start_now="${1:-yes}"
  write_runtime_env
  write_runner
  os="$(detect_os)"
  case "$os" in
    openwrt) write_openwrt ;;
    systemd) write_systemd ;;
    openrc) write_openrc ;;
    sysv) write_sysv ;;
    *) warn "未识别到受支持的 init 系统。已写入运行脚本：$CONF/run.sh"; return ;;
  esac
  if [ "$start_now" != yes ]; then
    case "$os" in
      systemd) systemctl disable --now easytier.service >/dev/null 2>&1 || : ;;
      openwrt) /etc/init.d/easytier stop >/dev/null 2>&1 || :; /etc/init.d/easytier disable >/dev/null 2>&1 || : ;;
      openrc) rc-service easytier stop >/dev/null 2>&1 || :; rc-update del easytier default >/dev/null 2>&1 || : ;;
      sysv) /etc/init.d/easytier stop >/dev/null 2>&1 || :; if have update-rc.d; then update-rc.d -f easytier remove >/dev/null 2>&1 || :; fi ;;
    esac
    return 0
  fi
  validate_start_config || return 1
  if [ "$os" = systemd ]; then systemctl restart easytier.service >/dev/null 2>&1 || systemctl start easytier.service >/dev/null 2>&1 || :
  elif [ "$os" = openwrt ] || [ "$os" = openrc ] || [ "$os" = sysv ]; then /etc/init.d/easytier restart >/dev/null 2>&1 || /etc/init.d/easytier start >/dev/null 2>&1 || :
  fi
}
install_all() {
  need_root
  ensure_tools
  load_settings
  previous_mode="$RUN_MODE"
  say "选择运行模式："
  say "1. 核心 + 本地 Web 管理端（资源占用较高）"
  say "2. 仅核心 + 本地 TOML 配置（轻量模式，默认）"
  say "3. 仅核心 + 远程 Web 控制台（轻量模式）"
  printf '请选择 [1-3，默认 2]：'; read -r x || x=""
  case "$x" in
    1) RUN_MODE="local-web" ;;
    3) RUN_MODE="remote-web" ;;
    *) RUN_MODE="config-file" ;;
  esac
  if [ "$RUN_MODE" = "local-web" ] && [ "$previous_mode" != "local-web" ]; then
    # Refresh the auto-detected address when switching from a non-Web mode;
    # the saved value may be the router WAN IP rather than its LAN address.
    API_HOST="$(detect_lan_ip)"
    [ -n "$API_HOST" ] || API_HOST="127.0.0.1"
  fi
  # The previous mode may have stored ports as 0; normalize after the user
  # chooses local Web, not only while loading the previous mode's settings.
  if [ "$RUN_MODE" = "local-web" ]; then
    valid_port "$WEB_PORT" || WEB_PORT="$DEFAULT_WEB_PORT"
    valid_port "$CONFIG_PORT" || CONFIG_PORT="$DEFAULT_CONFIG_PORT"
    valid_port "$NODE_PORT" || NODE_PORT="$DEFAULT_NODE_PORT"
  fi
  if [ "$RUN_MODE" = "local-web" ]; then
    printf 'Web/API 端口 [%s]: ' "$WEB_PORT"; read -r x || x=""; [ -n "$x" ] && WEB_PORT="$x"
    valid_port "$WEB_PORT" || die "Web/API 端口无效。"
    printf '配置服务器 UDP 端口 [%s]: ' "$CONFIG_PORT"; read -r x || x=""; [ -n "$x" ] && CONFIG_PORT="$x"
    valid_port "$CONFIG_PORT" || die "配置服务器端口无效。"
    printf 'Web 页面 API 访问 IP [%s]: ' "$API_HOST"; read -r x || x=""; [ -n "$x" ] && API_HOST="$x"
    [ -n "$API_HOST" ] || API_HOST="127.0.0.1"
    printf '本机在 Web 配置服务器中的用户名 [%s]: ' "$USERNAME"; read -r x || x=""; [ -n "$x" ] && USERNAME="$x"
    case "$USERNAME" in *[!A-Za-z0-9_.-]*|'') die "用户名只能包含字母、数字、点、下划线和连字符。";; esac
  elif [ "$RUN_MODE" = "remote-web" ]; then
    printf '远程配置服务器完整地址（例 udp://192.168.1.10:22020/admin）：'; read -r REMOTE_URL || REMOTE_URL=""
    case "$REMOTE_URL" in udp://*|tcp://*|ws://*|wss://*) ;; *) die "地址必须以 udp://、tcp://、ws:// 或 wss:// 开头。";; esac
    WEB_PORT="0"
    CONFIG_PORT="0"
  else
    WEB_PORT="0"
    CONFIG_PORT="0"
  fi
  save_settings
  get_asset_and_extract
  make_config
  if [ "$RUN_MODE" = "config-file" ]; then
    install_service no
  else
    install_service yes
  fi
  say ""
  info "安装流程完成。"
  case "$RUN_MODE" in
    local-web)
      say "Web 地址：http://${API_HOST}:${WEB_PORT}"
      say "配置服务器：udp://0.0.0.0:${CONFIG_PORT}"
      say "核心连接地址：udp://127.0.0.1:${CONFIG_PORT}/${USERNAME}"
      ;;
    config-file) say "运行模式：仅核心 + 本地配置文件"; say "配置文件：$DATA/config.toml"; say "服务已保持停止且未设置开机自启。请先编辑配置文件，完成后回到菜单选择 4 启动服务。" ;;
    remote-web) say "运行模式：仅核心 + 远程 Web 控制台"; say "远程配置服务器：$REMOTE_URL" ;;
  esac
  say "日志：systemd 可用 journalctl -u easytier -f；OpenWrt 可用 logread -e easytier。"
}

restart_service() {
  load_settings
  validate_start_config || return 1
  os="$(detect_os)"
  case "$os" in
    systemd) systemctl restart easytier.service ;;
    openwrt|openrc|sysv) /etc/init.d/easytier restart ;;
    *) warn "当前系统没有可识别的服务管理器，请运行 $CONF/run.sh";;
  esac
}
service_action() {
  need_root
  action="$1"; os="$(detect_os)"
  load_settings
  case "$action" in start|restart) validate_start_config || return 1 ;; esac
  case "$os" in
    systemd)
      if [ "$action" = start ]; then systemctl enable easytier.service >/dev/null 2>&1 || :; fi
      systemctl "$action" easytier.service
      ;;
    openwrt)
      if [ "$action" = start ]; then /etc/init.d/easytier enable >/dev/null 2>&1 || :; fi
      /etc/init.d/easytier "$action"
      ;;
    openrc)
      if [ "$action" = start ]; then rc-update add easytier default >/dev/null 2>&1 || :; fi
      rc-service easytier "$action"
      ;;
    sysv)
      if [ "$action" = start ] && have update-rc.d; then update-rc.d easytier defaults >/dev/null 2>&1 || :; fi
      /etc/init.d/easytier "$action"
      ;;
    *) warn "未检测到服务管理器。";;
  esac
}
edit_ports() {
  need_root
  load_settings
  if [ "$RUN_MODE" != "local-web" ]; then
    warn "当前运行模式为 $RUN_MODE，不使用本地 Web/配置服务器端口设置。请在对应模式的 TOML 配置或远程控制端修改参数。"
    return 0
  fi
  say "1. 修改 EasyTier 节点监听端口（当前：$NODE_PORT）"
  say "2. 修改 Web/API 端口（当前：$WEB_PORT）"
  say "3. 修改配置服务器端口（当前：$CONFIG_PORT/UDP）"
  say "4. 修改 Web API 访问 IP（当前：$API_HOST）"
  printf '选择：'; read -r c || c=""
  case "$c" in
    1)
      printf '输入新的节点监听端口：'; read -r x || x=""
      valid_port "$x" || { warn "端口无效"; return; }
      NODE_PORT="$x"
      if [ -f "$DATA/core.args" ]; then
        awk -v p="$NODE_PORT" '
          /^--listeners$/ { print; if (getline) { print p; next } }
          /^--listeners=/ { print "--listeners=" p; next }
          { print }
        ' "$DATA/core.args" > "$DATA/core.args.tmp" && mv "$DATA/core.args.tmp" "$DATA/core.args"
        if ! grep -q '^--listeners$\|^--listeners=' "$DATA/core.args"; then
          printf '\n--listeners\n%s\n' "$NODE_PORT" >> "$DATA/core.args"
        fi
      fi
      ;;
    2)
      printf '输入新的 Web/API 端口：'; read -r x || x=""
      valid_port "$x" || { warn "端口无效"; return; }
      WEB_PORT="$x"
      ;;
    3)
      printf '输入新的配置服务器 UDP 端口：'; read -r x || x=""
      valid_port "$x" || { warn "端口无效"; return; }
      CONFIG_PORT="$x"
      if [ -f "$DATA/core.args" ]; then
        sed "s#127.0.0.1:[0-9][0-9]*/#127.0.0.1:${CONFIG_PORT}/#" "$DATA/core.args" > "$DATA/core.args.tmp" && mv "$DATA/core.args.tmp" "$DATA/core.args"
      fi
      ;;
    4)
      printf '输入可被浏览器访问的设备 IP/主机名：'; read -r x || x=""
      [ -n "$x" ] || { warn "不能为空"; return; }
      API_HOST="$x"
      ;;
    *) return ;;
  esac
  save_settings
  write_runtime_env
  write_runner
  install_service
  info "配置已更新并尝试重启服务。"
}

download_settings() {
  need_root
  load_settings
  say "当前通用镜像前缀：$MIRROR"
  say "下载顺序为 Gitee Release → 配置的通用 GitHub 镜像 → GitHub 官方源。通用镜像用于代理完整 GitHub URL，例如 https://ghfast.top/。输入 official 清空。"
  printf '输入新的通用镜像前缀（回车保持，输入 official 清空）：'; read -r x || x=""
  if [ "$x" = official ]; then MIRROR=""
  elif [ -n "$x" ]; then MIRROR="${x%/}/"; fi
  save_settings
  info "下载源设置已保存。"
  printf '测试通用镜像可访问性？[y/N] '; read -r x || x=""
  case "$x" in y|Y|yes|YES)
    download_tool
    [ "$DL_TOOL" != none ] || { warn "缺少 curl/wget"; return; }
    mirror_test_file="${TMPDIR:-/tmp}/easytier-mirror-test.$$"
    if [ -n "$MIRROR" ]; then
      # Test an actual Raw file through the configured mirror. Do not test GitHub API:
      # general-purpose download mirrors commonly do not proxy API endpoints.
      mirror_test_url="${MIRROR%/}/https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}/${SCRIPT_PATH}"
      mirror_test_label="通用镜像"
    else
      # With no mirror configured, test the official Raw endpoint instead.
      mirror_test_url="https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}/${SCRIPT_PATH}"
      mirror_test_label="GitHub 官方 Raw 源"
    fi
    rm -f "$mirror_test_file"
    if download_file "$mirror_test_url" "$mirror_test_file" >/dev/null 2>&1 && valid_installer_script "$mirror_test_file"; then
      info "$mirror_test_label Raw 脚本下载正常。"
    else
      warn "$mirror_test_label Raw 脚本测试失败；请检查地址、网络或仓库文件是否可访问。"
    fi
    rm -f "$mirror_test_file" ;;
  esac
}
show_status() {
  say "系统类型：$(detect_os)"
  say "CPU 架构：$(detect_arch)"
  say "安装目录：$BASE"
  say "核心：$([ -x "$CORE" ] && echo 已安装 || echo 未安装)"
  say "Web：$([ -x "$WEB" ] && echo 已安装 || echo 未安装)"
  if have systemctl; then systemctl --no-pager --full status easytier.service 2>/dev/null | head -n 12
  elif [ -x /etc/init.d/easytier ]; then /etc/init.d/easytier status 2>/dev/null || :
  fi
  load_settings
  say "运行模式：$RUN_MODE"
  if [ "$RUN_MODE" = "local-web" ] && [ -x "$WEB" ]; then
    say "Web/API 端口：$WEB_PORT"
    say "配置服务器端口：$CONFIG_PORT/UDP"
    say "Web API 地址：http://${API_HOST:-127.0.0.1}:${WEB_PORT}"
  else
    say "Web/API 端口：未配置"
    [ "$RUN_MODE" = "config-file" ] || say "配置服务器端口：未配置"
  fi
  [ -n "${REMOTE_URL:-}" ] && say "远程配置服务器：$REMOTE_URL"
  say "用户名：$USERNAME"
}
show_logs() {
  if have journalctl; then journalctl -u easytier.service -n 100 --no-pager
  elif have logread; then logread | grep -i easytier | tail -n 100
  else warn "请查看系统日志，或前台运行 $CONF/run.sh"
  fi
}
update_script() {
  if ! is_root; then warn "请使用 root 运行，才能更新 /usr/bin/et。"; return 1; fi
  load_settings
  case "$SCRIPT_REPO" in
    YOUR_GITHUB_USERNAME/*|*/YOUR_EASYTIER_INSTALLER_REPO|""|*YOUR_GITHUB_USERNAME*|*YOUR_EASYTIER_INSTALLER_REPO*)
      warn "请先检查脚本顶部的 SCRIPT_REPO（格式：用户名/仓库名）。"
      return 1
      ;;
  esac
  download_tool
  if [ "$DL_TOOL" = none ]; then warn "缺少 curl/wget，无法更新安装脚本。"; return 1; fi
  SCRIPT_INSTALL_PATH="/usr/bin/et"
  if [ -f "$SCRIPT_INSTALL_PATH" ] && grep -q 'EasyTier 跨平台安装管理工具\|EasyTier cross-platform installer' "$SCRIPT_INSTALL_PATH" 2>/dev/null; then
    target="$SCRIPT_INSTALL_PATH"
  else
    target="$0"
    case "$target" in /*) ;; *) target="$(pwd)/$target" ;; esac
  fi
  if [ ! -f "$target" ]; then warn "无法定位当前脚本文件：$target。请先通过下载到文件的方式运行安装脚本。"; return 1; fi
  tmp="${target}.new.$$"
  official_script_url="https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}/${SCRIPT_PATH}"
  cdn_script_url="https://jsd.onmicrosoft.cn/gh/${SCRIPT_REPO}@${SCRIPT_BRANCH}/${SCRIPT_PATH}"
  rm -f "$tmp"

  # Order: jsDelivr mirror -> configured general GitHub mirror -> official Raw.
  info "[1/3] 通过 jsDelivr 镜像更新安装脚本：$cdn_script_url"
  if download_file "$cdn_script_url" "$tmp" >/dev/null 2>&1 && valid_installer_script "$tmp"; then
    info "jsDelivr 镜像下载完成，脚本身份和语法检查通过。"
  else
    rm -f "$tmp"
    if [ -n "${MIRROR:-}" ]; then
      mirror_script_url="${MIRROR%/}/https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}/${SCRIPT_PATH}"
      info "[2/3] 通过配置的 GitHub 镜像更新安装脚本：$mirror_script_url"
      if download_file "$mirror_script_url" "$tmp" >/dev/null 2>&1 && valid_installer_script "$tmp"; then
        info "配置的镜像下载完成，脚本身份和语法检查通过。"
      else
        warn "配置的镜像下载失败或内容无效，自动回退 GitHub 官方 Raw 源。"
        rm -f "$tmp"
      fi
    else
      info "未配置通用 GitHub 镜像，跳过第二个来源。"
    fi
  fi

  if [ ! -s "$tmp" ]; then
    info "[3/3] 从 GitHub 官方 Raw 地址更新安装脚本：$official_script_url"
    if ! download_file "$official_script_url" "$tmp" >/dev/null 2>&1 || ! valid_installer_script "$tmp"; then
      rm -f "$tmp"
      warn "安装脚本下载失败或内容无效。已依次尝试 jsDelivr、配置的镜像（如已配置）和 GitHub 官方 Raw。"
      return 1
    fi
    info "GitHub 官方源下载完成，脚本身份和语法检查通过。"
  fi
  if ! chmod 755 "$tmp"; then rm -f "$tmp"; warn "无法设置新脚本权限。"; return 1; fi
  cp -p "$target" "${target}.bak" 2>/dev/null || :
  if ! mv "$tmp" "$target"; then rm -f "$tmp"; warn "替换脚本失败；旧脚本仍应保留。"; return 1; fi
  info "安装管理脚本更新完成。"
  say "旧脚本备份：${target}.bak"
  say "正在重新启动最新版管理菜单……"
  # Replace this process with the just-updated script so the user immediately
  # lands in the new version's menu instead of continuing in the old process.
  exec "$target" "$@"
  warn "无法启动更新后的管理脚本：$target"
  return 1
}

update_all() {
  need_root
  load_settings
  [ -x "$CORE" ] || die "尚未安装 EasyTier 核心，请先选择菜单 1 安装。"
  ensure_tools
  was_active=no
  service_is_active && was_active=yes
  VERSION="latest"
  get_asset_and_extract
  write_runtime_env
  write_runner
  if [ "$was_active" = yes ]; then
    restart_service || die "更新已完成，但服务重启失败。请检查配置和日志。"
  else
    info "核心更新完成；更新前服务处于停止状态，保持停止，不自动启动。"
  fi
  info "更新完成。"
}
uninstall_all() {
  need_root
  printf '确认卸载全部 EasyTier？将删除核心、服务、配置、数据库及 et 管理脚本，此操作不可恢复。[y/N] '
  read -r answer || answer=""
  case "$answer" in y|Y|yes|YES) ;; *) info "已取消卸载。"; return 1 ;; esac

  os="$(detect_os)"
  # Stop the service first, then disable its boot entry before deleting init files.
  case "$os" in
    systemd) systemctl stop easytier.service >/dev/null 2>&1 || :; systemctl disable easytier.service >/dev/null 2>&1 || : ;;
    openwrt) /etc/init.d/easytier stop >/dev/null 2>&1 || :; /etc/init.d/easytier disable >/dev/null 2>&1 || : ;;
    openrc) rc-service easytier stop >/dev/null 2>&1 || :; rc-update del easytier default >/dev/null 2>&1 || : ;;
    sysv)
      /etc/init.d/easytier stop >/dev/null 2>&1 || :
      if have update-rc.d; then update-rc.d -f easytier remove >/dev/null 2>&1 || :; fi
      if have chkconfig; then chkconfig --del easytier >/dev/null 2>&1 || :; fi
      ;;
  esac

  # Remove stale boot links as well, including links left by a previous init system.
  rm -f /etc/systemd/system/multi-user.target.wants/easytier.service
  rm -f /etc/rc.d/*easytier* /etc/runlevels/*/easytier
  rm -f /etc/rc*.d/*easytier*
  rm -f /etc/systemd/system/easytier.service /etc/init.d/easytier
  if have systemctl; then systemctl daemon-reload >/dev/null 2>&1 || :; fi

  # Runtime launch files and installed components are not user data; always remove them.
  rm -f "$CONF/run.sh" "$CONF/runtime.env"
  rm -rf "$BIN"

  # Full uninstall: remove all EasyTier data/configuration and the manager itself.
  rm -rf "$BASE" "$CONF"
  if [ -f /usr/bin/et ] && grep -q 'EasyTier 跨平台安装管理工具\|EasyTier cross-platform installer' /usr/bin/et 2>/dev/null; then
    rm -f /usr/bin/et
  fi
  if [ -f /usr/bin/et.bak ] && grep -q 'EasyTier 跨平台安装管理工具\|EasyTier cross-platform installer' /usr/bin/et.bak 2>/dev/null; then
    rm -f /usr/bin/et.bak
  fi
  rm -f /usr/bin/et.new.*
  info "EasyTier 核心、服务、配置、数据库及 et 管理脚本已全部卸载。"
  return 0
}

edit_local_config() {
  need_root
  mkdir_p "$DATA"
  [ -f "$DATA/config.toml" ] || cat > "$DATA/config.toml" <<'EOF'
# EasyTier TOML 配置文件
# 使用官方配置助手生成后粘贴到这里：https://easytier.cn/guide/network/config-file.html
EOF
  if have vi; then vi "$DATA/config.toml"
  elif have nano; then nano "$DATA/config.toml"
  else warn "未找到 vi/nano，请手动编辑：$DATA/config.toml"; return 1
  fi
  info "配置已编辑；若当前运行模式是 config-file，请重启 EasyTier 服务生效。"
}
set_remote_web() {
  need_root
  load_settings
  printf '远程配置服务器完整地址（例 udp://192.168.1.10:22020/admin）：'; read -r x || x=""
  case "$x" in udp://*|tcp://*|ws://*|wss://*) REMOTE_URL="$x";; *) warn "地址必须以 udp://、tcp://、ws:// 或 wss:// 开头。"; return 1;; esac
  RUN_MODE="remote-web"
  rm -f "$WEB"
  save_settings
  write_runtime_env
  write_runner
  install_service
  info "已切换为远程 Web 控制模式。"
}

menu() {
  while :; do
    load_settings
    clear 2>/dev/null || :
    say "=============================================="
    say "       EasyTier 跨平台安装管理工具"
    say "=============================================="
    say "脚本版本：v$SCRIPT_VERSION"
    say "系统：$(detect_os)    架构：$(detect_arch)"
    say "模式：$RUN_MODE    核心：$([ -x "$CORE" ] && echo 已安装 || echo 未安装)    Web：$([ -x "$WEB" ] && echo 已安装 || echo 未安装)"
    say "EasyTier 目录占用：$(easytier_dir_size)（$BASE）"
    if [ "$RUN_MODE" = "local-web" ] && [ -x "$WEB" ]; then
      say "Web 端口：$WEB_PORT    配置服务端口：$CONFIG_PORT/UDP"
    else
      say "Web 端口：未配置    配置服务端口：未配置"
    fi
    say "下载源：Gitee Release → ${MIRROR:-配置的 GitHub 镜像（未设置则跳过）} → GitHub 官方源"
    say "----------------------------------------------"
    say "1. 安装 EasyTier（选择本地 Web / 本地配置 / 远程 Web）"
    say "2. 更新 EasyTier 核心/组件"
    say "3. 更新安装脚本（自己的 GitHub 仓库）"
    say "4. 启动服务"
    say "5. 停止服务"
    say "6. 重启服务"
    say "7. 修改端口 / Web API 地址"
    say "8. 编辑本地 TOML 配置文件"
    say "9. 设置远程 Web 配置服务器"
    say "10. 下载源 / 镜像加速设置"
    say "11. 查看运行状态"
    say "12. 查看日志"
    say "13. 卸载全部 EasyTier（核心、服务、配置、数据库及 et 管理脚本）"
    say "0. 退出"
    say "=============================================="
    printf '请输入选项：'
    if ! read -r choice; then
      warn "读取菜单输入失败，请检查终端输入后重试；菜单不会因此退出。"
      sleep 1
      continue
    fi
    case "$choice" in
      # Run menu actions that may call die in a subshell: a failed operation
      # returns to this loop instead of terminating the interactive manager.
      1) (install_all); pause ;;
      2) (update_all); pause ;;
      3) update_script; [ "$?" -eq 0 ] || pause ;;
      4) (service_action start); pause ;;
      5) (service_action stop); pause ;;
      6) (service_action restart); pause ;;
      7) (edit_ports); pause ;;
      8) (edit_local_config); pause ;;
      9) (set_remote_web); pause ;;
      10) (download_settings); pause ;;
      11) (show_status); pause ;;
      12) (show_logs); pause ;;
      13)
        if (uninstall_all); then exit 0; else pause; fi
        ;;
      0) exit 0 ;;
      *) warn "无效选项：$choice。请输入 0-13 之间的菜单编号。"; pause ;;
    esac
  done
}

# Ensure settings path exists but do not require root merely to show help.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
EasyTier 跨平台安装管理工具
用法：
  et                      进入交互菜单
  sh easytier.sh          进入交互菜单
  sh easytier.sh --help   显示帮助

安装时需要 root 权限。核心组件下载顺序：Gitee Release、配置的 GitHub 镜像、GitHub 官方 Release。
管理命令：安装后可直接运行 et。
脚本自更新：从菜单选择“更新安装脚本”，更新固定路径中的管理脚本。
首次安装默认选择轻量的“核心 + 本地 TOML 配置”模式；需要 Web 页面时可选择本地 Web 模式。仅本地 Web 模式会安装 easytier-web-embed。
交互脚本可通过文件运行；若使用管道执行，必须有可用的控制终端。推荐先下载到文件，以便明确检查下载结果。
EOF
  exit 0
fi

# A menu needs a real terminal. If invoked non-interactively with no controlling
# terminal, fail clearly instead of reading script text as menu answers.
if [ ! -t 0 ] && ! ( : </dev/tty ) 2>/dev/null; then
  die "这是交互式管理菜单，需要终端输入。请在 SSH/终端中运行，或先下载到文件再执行。"
fi

# Persist the management script outside /tmp so menu option 3 can update the
# actual installed copy instead of replacing a temporary download.
SCRIPT_INSTALL_PATH="/usr/bin/et"
script_self="$0"
case "$script_self" in
  /*) ;;
  *) script_self="$(pwd)/$script_self" ;;
esac
if [ "$script_self" != "$SCRIPT_INSTALL_PATH" ]; then
  if ! is_root; then
    warn "建议在 root 终端运行，以便将管理脚本安装到 $SCRIPT_INSTALL_PATH；安装组件和系统服务需要 root 权限。"
  elif [ -e "$SCRIPT_INSTALL_PATH" ] && ! grep -q 'EasyTier 跨平台安装管理工具\|EasyTier cross-platform installer' "$SCRIPT_INSTALL_PATH" 2>/dev/null; then
    warn "$SCRIPT_INSTALL_PATH 已存在且不像本安装脚本。为避免覆盖其他程序，不会覆盖它；当前脚本仍可继续运行。"
  else
    bootstrap_tmp="${SCRIPT_INSTALL_PATH}.new.$$"
    bootstrap_ok=no
    if [ -f "$script_self" ] && [ -r "$script_self" ]; then
      if cp "$script_self" "$bootstrap_tmp" 2>/dev/null && valid_installer_script "$bootstrap_tmp"; then bootstrap_ok=yes; fi
    else
      # When launched as `curl ... | sh`, $0 is the shell, not a script file.
      # Fetch a verified persistent copy so future self-updates have a real target.
      download_tool
      if [ "$DL_TOOL" != none ]; then
        bootstrap_url="https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}/${SCRIPT_PATH}"
        bootstrap_cdn_url="https://jsd.onmicrosoft.cn/gh/${SCRIPT_REPO}@${SCRIPT_BRANCH}/${SCRIPT_PATH}"
        # For pipe launches, first fetch a persistent copy from jsDelivr, then
        # the configured mirror, and finally GitHub Raw. Validate each result.
        download_file "$bootstrap_cdn_url" "$bootstrap_tmp" >/dev/null 2>&1 || rm -f "$bootstrap_tmp"
        valid_installer_script "$bootstrap_tmp" || rm -f "$bootstrap_tmp"
        if [ ! -s "$bootstrap_tmp" ] && [ -n "$DEFAULT_MIRROR" ]; then
          download_file "${DEFAULT_MIRROR%/}/https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}/${SCRIPT_PATH}" "$bootstrap_tmp" >/dev/null 2>&1 || rm -f "$bootstrap_tmp"
          valid_installer_script "$bootstrap_tmp" || rm -f "$bootstrap_tmp"
        fi
        if [ ! -s "$bootstrap_tmp" ]; then
          download_file "$bootstrap_url" "$bootstrap_tmp" >/dev/null 2>&1 || rm -f "$bootstrap_tmp"
        fi
        if valid_installer_script "$bootstrap_tmp"; then bootstrap_ok=yes; fi
      fi
    fi
    if [ "$bootstrap_ok" = yes ] && chmod 755 "$bootstrap_tmp" 2>/dev/null && mv -f "$bootstrap_tmp" "$SCRIPT_INSTALL_PATH" 2>/dev/null; then
      info "安装管理脚本到：$SCRIPT_INSTALL_PATH"
      exec "$SCRIPT_INSTALL_PATH" "$@"
    fi
    rm -f "$bootstrap_tmp"
    warn "无法将管理脚本安装到 $SCRIPT_INSTALL_PATH，将继续运行当前副本；请使用下载到文件的方式运行以便重试。"
  fi
fi

menu

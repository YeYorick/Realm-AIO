#!/usr/bin/env bash
set -euo pipefail

############################################
# Realm AIO 一键脚本（中转机/落地机融合）
# - 自动检测架构下载最新 realm
# - 向导：生成“中转机配置”和“落地机配置”（支持 TLS / WS / WSS）
# - 落地机 TLS/WSS：可自动生成自签证书（cert/key）
# - systemd 自启动
############################################

RED="\033[31m\033[01m"; GREEN="\033[32m\033[01m"; YELLOW="\033[33m\033[01m"; NC="\033[0m"
info(){ echo -e "${GREEN}$*${NC}"; }
warn(){ echo -e "${YELLOW}$*${NC}"; }
err(){  echo -e "${RED}$*${NC}"; exit 1; }

REALM_REPO="zhboner/realm"

INSTALL_BIN="/usr/local/bin/realm"
CONF_DIR="/etc/realm"
CONF_FILE="/etc/realm/realm.toml"
CERT_DIR="/etc/realm/certs"
CERT_CRT="/etc/realm/certs/realm.crt"
CERT_KEY="/etc/realm/certs/realm.key"
SERVICE_FILE="/etc/systemd/system/realm.service"

CMD="${1:-help}"; shift || true

need_root(){ [[ "$(id -u)" == "0" ]] || err "请使用 root 权限运行（sudo）"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || err "缺少依赖命令：$1"; }
has_systemd(){ command -v systemctl >/dev/null 2>&1; }

detect_arch_asset() {
  local arch
  arch="$(uname -m | tr '[:upper:]' '[:lower:]')"
  case "$arch" in
    x86_64|amd64) echo "realm-x86_64-unknown-linux-gnu.tar.gz" ;;
    aarch64|arm64) echo "realm-aarch64-unknown-linux-gnu.tar.gz" ;;
    armv7l|armv7|armhf) echo "realm-armv7-unknown-linux-gnueabihf.tar.gz" ;;
    i386|i686) echo "realm-i686-unknown-linux-gnu.tar.gz" ;;
    *) err "不支持的 CPU 架构：$arch（uname -m）" ;;
  esac
}

github_latest_tag() {
  local api="https://api.github.com/repos/${REALM_REPO}/releases/latest"
  local tag
  tag="$(curl -fsSL "$api" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
  [[ -n "${tag:-}" ]] || err "获取最新版本失败（GitHub API）"
  echo "$tag"
}

download_and_install() {
  need_cmd curl; need_cmd tar; need_cmd install

  local tag asset url tmpdir
  tag="$(github_latest_tag)"
  asset="$(detect_arch_asset)"
  url="https://github.com/${REALM_REPO}/releases/download/${tag}/${asset}"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  info "最新版本：${tag}"
  info "检测到架构资源：${asset}"
  info "开始下载：${url}"

  if ! curl -fL --retry 3 --connect-timeout 10 -o "${tmpdir}/${asset}" "$url"; then
    if [[ "$asset" == "realm-armv7-unknown-linux-gnueabihf.tar.gz" ]]; then
      warn "未找到 armv7 gnueabihf 资源，尝试备用资源：realm-armv7-unknown-linux-gnu.tar.gz"
      asset="realm-armv7-unknown-linux-gnu.tar.gz"
      url="https://github.com/${REALM_REPO}/releases/download/${tag}/${asset}"
      curl -fL --retry 3 --connect-timeout 10 -o "${tmpdir}/${asset}" "$url" || err "下载失败（备用资源也失败）"
    else
      err "下载失败：请检查网络或 GitHub 可用性"
    fi
  fi

  tar -zxf "${tmpdir}/${asset}" -C "$tmpdir"
  [[ -f "${tmpdir}/realm" ]] || err "解压后未找到 realm 可执行文件"

  install -m 0755 "${tmpdir}/realm" "${INSTALL_BIN}"
  info "已安装可执行文件 -> ${INSTALL_BIN}"
}

write_systemd() {
  has_systemd || { warn "未检测到 systemd，跳过服务创建"; return 0; }

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=realm (AIO)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_BIN} -c ${CONF_FILE}
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable realm >/dev/null
  systemctl restart realm
  info "realm 服务已启动并设置为开机自启"
}

status_service() {
  has_systemd || err "未检测到 systemd，无法查看服务状态"
  systemctl --no-pager -l status realm || true
}

uninstall_all() {
  need_root
  warn "正在停止 realm 服务（如已存在）..."
  if has_systemd; then
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
  fi

  warn "正在删除 systemd 服务文件..."
  rm -f "$SERVICE_FILE"

  warn "正在删除 realm 可执行文件..."
  rm -f "$INSTALL_BIN"

  warn "正在删除 realm 配置目录..."
  rm -rf "$CONF_DIR"

  if has_systemd; then
    systemctl daemon-reload || true
  fi

  info "realm 已完全卸载（程序 / 配置 / 服务）"
}

gen_self_signed_cert() {
  need_cmd openssl
  mkdir -p "$CERT_DIR"
  if [[ -f "$CERT_CRT" && -f "$CERT_KEY" ]]; then
    warn "检测到证书已存在，跳过生成：$CERT_CRT / $CERT_KEY"
    return 0
  fi

  # CN 不重要（realm 通常走 sni/servername + insecure 方式）
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CERT_KEY" -out "$CERT_CRT" -days 3650 \
    -subj "/CN=realm-self-signed" >/dev/null 2>&1

  chmod 600 "$CERT_KEY"
  chmod 644 "$CERT_CRT"
  info "已生成自签证书：$CERT_CRT"
  info "已生成私钥文件：$CERT_KEY"
}

# 生成基础头部
write_config_header() {
  local log_level="${1:-warn}"
  local log_output="${2:-/var/log/realm.log}"
  local no_tcp="${3:-false}"
  local use_udp="${4:-true}"

  mkdir -p "$CONF_DIR"

  cat >"$CONF_FILE" <<EOF
[log]
level = "${log_level}"
output = "${log_output}"

[network]
no_tcp = ${no_tcp}
use_udp = ${use_udp}

EOF
}

# 追加一个 endpoints
append_endpoint() {
  local listen="$1"
  local remote="$2"
  local listen_transport="${3:-}"
  local remote_transport="${4:-}"

  {
    echo "[[endpoints]]"
    echo "listen = \"${listen}\""
    echo "remote = \"${remote}\""
    if [[ -n "$listen_transport" ]]; then
      echo "listen_transport = \"${listen_transport}\""
    fi
    if [[ -n "$remote_transport" ]]; then
      echo "remote_transport = \"${remote_transport}\""
    fi
    echo
  } >>"$CONF_FILE"
}

pick_transport_mode() {
  echo "请选择加密/伪装方式："
  echo "  1) 不加密（plain）"
  echo "  2) TLS（纯 TLS，推荐配合自签 + 中转端 insecure）"
  echo "  3) WS（无 TLS，只有 WebSocket 伪装，不加密）"
  echo "  4) WSS（WS + TLS，加密 + 伪装，推荐）"
  read -r -p "请输入 1-4： " mode
  case "${mode:-}" in
    1) echo "plain" ;;
    2) echo "tls" ;;
    3) echo "ws" ;;
    4) echo "wss" ;;
    *) err "输入无效" ;;
  esac
}

wizard() {
  need_root
  need_cmd curl; need_cmd tar; need_cmd install

  echo "==== Realm AIO 向导（中转/落地融合）===="
  echo "你现在要配置哪一台？"
  echo "  1) 中转机（入口）"
  echo "  2) 落地机（出口）"
  read -r -p "请输入 1-2： " role

  # 先安装/更新二进制
  download_and_install

  # 通用参数
  read -r -p "日志等级（warn/info/debug/error，默认 warn）： " log_level
  log_level="${log_level:-warn}"
  read -r -p "日志输出路径（默认 /var/log/realm.log）： " log_output
  log_output="${log_output:-/var/log/realm.log}"

  read -r -p "是否启用 UDP 转发？(y/n，默认 y)： " udp_yn
  local use_udp="true"
  [[ "${udp_yn,,}" == "n" ]] && use_udp="false"

  read -r -p "是否禁用 TCP 转发？(y/n，默认 n)： " notcp_yn
  local no_tcp="false"
  [[ "${notcp_yn,,}" == "y" ]] && no_tcp="true"

  write_config_header "$log_level" "$log_output" "$no_tcp" "$use_udp"

  local mode
  mode="$(pick_transport_mode)"

  # 统一收集伪装参数（ws/wss）
  local ws_host="" ws_path="/"
  if [[ "$mode" == "ws" || "$mode" == "wss" ]]; then
    read -r -p "WS Host（伪装域名/Host 头，例如 www.amazon.com）： " ws_host
    ws_host="${ws_host:-www.amazon.com}"
    read -r -p "WS Path（例如 /abcd，默认 /）： " ws_path
    ws_path="${ws_path:-/}"
  fi

  # 统一收集 SNI/ServerName（tls/wss）
  local sni_name=""
  if [[ "$mode" == "tls" || "$mode" == "wss" ]]; then
    read -r -p "SNI/ServerName（例如 www.amazon.com）： " sni_name
    sni_name="${sni_name:-www.amazon.com}"
  fi

  # 注意：TLS 服务端 listen_transport 通常需要 cert/key（否则可能报错）
  local need_cert="0"
  if [[ "$role" == "2" && ( "$mode" == "tls" || "$mode" == "wss" ) ]]; then
    need_cert="1"
  fi

  if [[ "$need_cert" == "1" ]]; then
    read -r -p "落地机需要 TLS 证书：是否自动生成自签证书？(y/n，默认 y)： " cert_yn
    cert_yn="${cert_yn:-y}"
    if [[ "${cert_yn,,}" == "y" ]]; then
      gen_self_signed_cert
    else
      warn "你选择不自动生成证书。请确保你稍后手动放置证书："
      warn "  证书：$CERT_CRT"
      warn "  私钥：$CERT_KEY"
    fi
  fi

  echo
  info "开始添加转发规则（可添加多条；listen 直接回车结束）"
  local added="0"

  while true; do
    local listen_addr remote_addr target_addr
    read -r -p "本机监听 listen（如 0.0.0.0:10000）： " listen_addr || true
    [[ -z "${listen_addr:-}" ]] && break

    if [[ "$role" == "1" ]]; then
      # 中转机：remote 填“落地机 IP:端口”
      read -r -p "落地机地址 remote（如 1.1.1.1:20000）： " remote_addr || true
      [[ -z "${remote_addr:-}" ]] && err "remote 不能为空"

      # 中转机只需要 remote_transport（到落地机的加密/伪装）
      local remote_transport=""
      case "$mode" in
        plain)
          remote_transport=""
          ;;
        tls)
          # 中转机作为 TLS 客户端，常用 insecure（落地机自签/不校验）
          remote_transport="tls;sni=${sni_name};insecure"
          ;;
        ws)
          remote_transport="ws;host=${ws_host};path=${ws_path}"
          ;;
        wss)
          # WSS：ws + tls + insecure（落地机自签）
          # 注意：servername/sni 字段在不同版本/示例里会见到两种写法，
          # 这里用 sni 作为默认；如果你实际环境需要 servername，你也可以手动改配置。
          remote_transport="ws;host=${ws_host};path=${ws_path};tls;sni=${sni_name};insecure"
          ;;
      esac

      append_endpoint "$listen_addr" "$remote_addr" "" "$remote_transport"

      # 同时打印“落地机对应规则模板”（给你复制用）
      echo
      warn "【落地机对应规则模板】（复制到落地机向导/配置里）"
      case "$mode" in
        plain)
          echo "listen = \"0.0.0.0:$(echo "$remote_addr" | awk -F: '{print $2}')\""
          echo "remote = \"127.0.0.1:目标端口\""
          ;;
        tls)
          echo "listen = \"0.0.0.0:$(echo "$remote_addr" | awk -F: '{print $2}')\""
          echo "remote = \"127.0.0.1:目标端口\""
          echo "listen_transport = \"tls;cert=${CERT_CRT};key=${CERT_KEY}\""
          ;;
        ws)
          echo "listen = \"0.0.0.0:$(echo "$remote_addr" | awk -F: '{print $2}')\""
          echo "remote = \"127.0.0.1:目标端口\""
          echo "listen_transport = \"ws;host=${ws_host};path=${ws_path}\""
          ;;
        wss)
          echo "listen = \"0.0.0.0:$(echo "$remote_addr" | awk -F: '{print $2}')\""
          echo "remote = \"127.0.0.1:目标端口\""
          echo "listen_transport = \"ws;host=${ws_host};path=${ws_path};tls;cert=${CERT_CRT};key=${CERT_KEY}\""
          ;;
      esac
      echo

    elif [[ "$role" == "2" ]]; then
      # 落地机：remote 填“真实目标 IP:端口”（或本机 127.0.0.1:端口）
      read -r -p "真实目标地址 remote（如 127.0.0.1:443 或 8.8.8.8:222）： " target_addr || true
      [[ -z "${target_addr:-}" ]] && err "remote 不能为空"

      # 落地机需要 listen_transport（用于接收中转机的加密/伪装）
      local listen_transport=""
      case "$mode" in
        plain)
          listen_transport=""
          ;;
        tls)
          listen_transport="tls;cert=${CERT_CRT};key=${CERT_KEY}"
          ;;
        ws)
          listen_transport="ws;host=${ws_host};path=${ws_path}"
          ;;
        wss)
          listen_transport="ws;host=${ws_host};path=${ws_path};tls;cert=${CERT_CRT};key=${CERT_KEY}"
          ;;
      esac

      append_endpoint "$listen_addr" "$target_addr" "$listen_transport" ""
    else
      err "角色输入无效"
    fi

    added="1"
  done

  [[ "$added" == "1" ]] || warn "你没有添加任何 endpoints：realm 可启动，但不会转发任何端口"

  info "配置文件已写入 -> $CONF_FILE"

  write_systemd

  echo
  info "===== 完成 ====="
  info "可执行文件：$INSTALL_BIN"
  info "配置文件：  $CONF_FILE"
  if [[ "$need_cert" == "1" ]]; then
    info "证书文件：  $CERT_CRT"
    info "私钥文件：  $CERT_KEY"
  fi
  has_systemd && warn "修改配置后执行：systemctl restart realm"
}

help() {
  cat <<EOF
Realm AIO 一键脚本（中转/落地融合）

用法：
  sudo bash realm-aio.sh wizard     # 向导：选择中转机/落地机并生成配置+服务
  sudo bash realm-aio.sh install    # 仅安装/更新 realm 二进制
  sudo bash realm-aio.sh status     # 查看服务状态（systemd）
  sudo bash realm-aio.sh restart    # 重启服务（systemd）
  sudo bash realm-aio.sh uninstall  # 卸载（程序/配置/systemd）

说明：
- 中转机：生成 remote_transport（plain/tls/ws/wss）
- 落地机：生成 listen_transport；TLS/WSS 会用 cert/key（可自动生成自签）
EOF
}

case "$CMD" in
  wizard)    wizard ;;
  install)   need_root; download_and_install; info "已安装/更新 -> $INSTALL_BIN" ;;
  status)    status_service ;;
  restart)   has_systemd || err "未检测到 systemd"; systemctl restart realm; info "realm 已重启" ;;
  uninstall) uninstall_all ;;
  help|"" )  help ;;
  *) err "未知命令：$CMD（用 help 查看）" ;;
esac

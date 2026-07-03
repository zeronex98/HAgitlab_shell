#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "缺少命令: $1"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "请使用 root 或 sudo 执行该脚本"
  fi
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      fail "缺少变量: ${name}"
    fi
  done
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo dnf
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo yum
    return
  fi
  fail "未识别的包管理器，仅支持 apt/dnf/yum"
}

install_base_packages() {
  local pkg_mgr="$1"
  case "${pkg_mgr}" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar nfs-common
      ;;
    dnf)
      dnf install -y curl ca-certificates tar nfs-utils
      ;;
    yum)
      yum install -y curl ca-certificates tar nfs-utils
      ;;
  esac
}

install_docker() {
  local pkg_mgr="${1:-}"
  if ! command -v docker >/dev/null 2>&1; then
    [[ -n "${pkg_mgr}" ]] || fail "Docker 未安装，且当前已跳过联网安装"
    log "安装 Docker"
    curl -fsSL https://get.docker.com | sh
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
  fi

  if ! docker compose version >/dev/null 2>&1; then
    [[ -n "${pkg_mgr}" ]] || fail "docker compose 不可用，且当前已跳过联网安装"
    log "安装 Docker Compose 插件"
    case "${pkg_mgr}" in
      apt)
        apt-get install -y docker-compose-plugin
        ;;
      dnf)
        dnf install -y docker-compose-plugin
        ;;
      yum)
        yum install -y docker-compose-plugin
        ;;
    esac
  fi

  docker compose version >/dev/null 2>&1 || fail "docker compose 不可用"
}

ensure_fstab_entry() {
  local line="$1"
  local file="$2"
  if ! grep -Fqs "${line}" "${file}"; then
    printf '%s\n' "${line}" >> "${file}"
  fi
}

ensure_fstab_mount() {
  local source="$1"
  local target="$2"
  local fstype="$3"
  local options="$4"
  local dump="$5"
  local pass="$6"
  local file="$7"
  local line
  local tmp

  line="${source} ${target} ${fstype} ${options} ${dump} ${pass}"
  tmp="$(mktemp)"

  if [[ -f "${file}" ]]; then
    awk -v target="${target}" 'NF < 2 || $2 != target { print }' "${file}" > "${tmp}"
  fi

  printf '%s\n' "${line}" >> "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

ensure_permissions() {
  local target="$1"
  local mode="$2"
  if [[ -e "${target}" ]]; then
    chmod "${mode}" "${target}"
  fi
}

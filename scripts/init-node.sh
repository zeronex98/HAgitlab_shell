#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
[[ -f "${ROOT_DIR}/inventory.env" ]] || fail "缺少 ${ROOT_DIR}/inventory.env"
# shellcheck source=../inventory.env
source "${ROOT_DIR}/inventory.env"

NODE_NAME="${1:-}"
INIT_BACKUP_ENABLED="${INIT_BACKUP_ENABLED:-true}"
INIT_BACKUP_ROOT="${INIT_BACKUP_ROOT:-${NFS_MOUNT}/bootstrap-backups}"

CONTAINERS=()
PERSISTENT_DIRS=()
BACKUP_DIRS=()

usage() {
  cat <<'EOF'
用法:
  sudo bash scripts/init-node.sh node29
  sudo bash scripts/init-node.sh node25
  sudo bash scripts/init-node.sh node26
EOF
}

is_local_nfs_server() {
  local candidate

  case "${NFS_SERVER}" in
    127.0.0.1|localhost|localhost.localdomain)
      return 0
      ;;
  esac

  for candidate in \
    "$(hostname 2>/dev/null || true)" \
    "$(hostname -s 2>/dev/null || true)" \
    "$(hostname -f 2>/dev/null || true)"; do
    if [[ -n "${candidate}" && "${candidate}" == "${NFS_SERVER}" ]]; then
      return 0
    fi
  done

  if command -v hostname >/dev/null 2>&1; then
    for candidate in $(hostname -I 2>/dev/null); do
      if [[ "${candidate}" == "${NFS_SERVER}" ]]; then
        return 0
      fi
    done
  fi

  if command -v ip >/dev/null 2>&1; then
    while read -r candidate; do
      if [[ -n "${candidate}" && "${candidate}" == "${NFS_SERVER}" ]]; then
        return 0
      fi
    done < <(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1)
  fi

  return 1
}

mount_nfs() {
  if [[ "${SKIP_NFS_MOUNT:-false}" == "true" ]]; then
    log "跳过 NFS 挂载（SKIP_NFS_MOUNT=true）"
    [[ -d "${NFS_MOUNT}" ]] || fail "NFS 挂载点目录不存在: ${NFS_MOUNT}，请先手动创建或挂载"
    return 0
  fi

  mkdir -p "${NFS_MOUNT}"

  if mountpoint -q "${NFS_MOUNT}"; then
    return 0
  fi

  if is_local_nfs_server && [[ -d "${NFS_EXPORT}" ]]; then
    if [[ "${NFS_MOUNT}" == "${NFS_EXPORT}" ]]; then
      log "检测到当前主机即 NFS 服务端，直接使用本地导出目录: ${NFS_EXPORT}"
      return 0
    fi

    ensure_fstab_mount "${NFS_EXPORT}" "${NFS_MOUNT}" none "defaults,bind" 0 0 /etc/fstab
    mount --bind "${NFS_EXPORT}" "${NFS_MOUNT}"
  else
    ensure_fstab_mount "${NFS_SERVER}:${NFS_EXPORT}" "${NFS_MOUNT}" nfs "defaults,_netdev,nofail,x-systemd.automount" 0 0 /etc/fstab
    mount -t nfs -o defaults,_netdev,nofail,x-systemd.automount "${NFS_SERVER}:${NFS_EXPORT}" "${NFS_MOUNT}" || mount -a
  fi

  mountpoint -q "${NFS_MOUNT}" || fail "NFS 挂载失败: ${NFS_MOUNT}"
}

set_node_layout() {
  case "${NODE_NAME}" in
    node29)
      CONTAINERS=(postgres-node29 redis-sentinel-node29)
      PERSISTENT_DIRS=(
        "${NFS_MOUNT}/postgresql/data"
        "${NFS_MOUNT}/postgresql/conf"
        "${NFS_MOUNT}/redis/sentinel-node29"
      )
      BACKUP_DIRS=("${PERSISTENT_DIRS[@]}")
      ;;
    node25)
      CONTAINERS=(redis-node25 redis-sentinel-node25 gitlab-node25)
      PERSISTENT_DIRS=(
        "${NFS_MOUNT}/redis/node25"
        "${NFS_MOUNT}/redis/sentinel-node25"
        "${NFS_MOUNT}/gitlab/node25/config"
        "${NFS_MOUNT}/gitlab/node25/logs"
        "${NFS_MOUNT}/gitlab/node25/data"
        "${NFS_MOUNT}/gitlab/common"
        "${NFS_MOUNT}/gitlab/shared"
      )
      BACKUP_DIRS=("${PERSISTENT_DIRS[@]}")
      ;;
    node26)
      CONTAINERS=(redis-node26 redis-sentinel-node26 gitlab-node26)
      PERSISTENT_DIRS=(
        "${NFS_MOUNT}/redis/node26"
        "${NFS_MOUNT}/redis/sentinel-node26"
        "${NFS_MOUNT}/gitlab/node26/config"
        "${NFS_MOUNT}/gitlab/node26/logs"
        "${NFS_MOUNT}/gitlab/node26/data"
      )
      BACKUP_DIRS=("${PERSISTENT_DIRS[@]}")
      ;;
    *)
      usage
      fail "未知节点标识: ${NODE_NAME:-<empty>}"
      ;;
  esac
}

directory_has_entries() {
  local path="$1"

  [[ -d "${path}" ]] || return 1
  find "${path}" -mindepth 1 -print -quit | grep -q .
}

clear_directory_contents() {
  local path="$1"

  [[ -d "${path}" ]] || return 0
  case "${path}" in
    "${NFS_MOUNT}"|${NFS_MOUNT}/*) ;;
    *)
      fail "拒绝清理非 NFS 持久化目录: ${path}"
      ;;
  esac

  find "${path}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

inspect_node_state() {
  local container
  local path
  local clean_state=0

  for container in "${CONTAINERS[@]}"; do
    if docker container inspect "${container}" >/dev/null 2>&1; then
      log "发现历史容器: ${container}"
      docker ps -a --filter "name=^/${container}$" >&2 || true
      clean_state=1
    fi
  done

  for path in "${PERSISTENT_DIRS[@]}"; do
    if directory_has_entries "${path}"; then
      log "发现历史持久化目录内容: ${path}"
      clean_state=1
    fi
  done

  if (( clean_state == 0 )); then
    return 0
  fi

  return 1
}

stop_and_remove_containers() {
  local compose_file="${ROOT_DIR}/compose/${NODE_NAME}/docker-compose.yml"
  local container

  if [[ -f "${compose_file}" ]]; then
    docker compose --env-file "${ROOT_DIR}/inventory.env" -f "${compose_file}" down --remove-orphans >/dev/null 2>&1 || true
  fi

  for container in "${CONTAINERS[@]}"; do
    if docker container inspect "${container}" >/dev/null 2>&1; then
      log "停止并移除容器: ${container}"
      docker rm -f "${container}" >/dev/null
    fi
  done
}

backup_persistent_data() {
  local rel_paths=()
  local path
  local archive_dir
  local archive_path
  local timestamp

  if [[ "${INIT_BACKUP_ENABLED}" != "true" ]]; then
    log "跳过持久化目录备份（INIT_BACKUP_ENABLED=${INIT_BACKUP_ENABLED}）"
    return 0
  fi

  for path in "${BACKUP_DIRS[@]}"; do
    if directory_has_entries "${path}"; then
      rel_paths+=("${path#${NFS_MOUNT}/}")
    fi
  done

  if (( ${#rel_paths[@]} == 0 )); then
    log "没有需要备份的持久化目录"
    return 0
  fi

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  archive_dir="${INIT_BACKUP_ROOT}/${timestamp}"
  archive_path="${archive_dir}/${NODE_NAME}-persistent.tgz"

  mkdir -p "${archive_dir}"
  tar -czf "${archive_path}" -C "${NFS_MOUNT}" "${rel_paths[@]}"
  log "已备份持久化目录到 ${archive_path}（未导出 Docker 镜像文件）"
}

cleanup_persistent_data() {
  local path

  for path in "${PERSISTENT_DIRS[@]}"; do
    if [[ -d "${path}" ]]; then
      log "清理持久化目录: ${path}"
      clear_directory_contents "${path}"
    fi
  done
}

main() {
  local pkg_mgr=""

  require_root
  require_env \
    NFS_SERVER NFS_EXPORT NFS_MOUNT \
    DB_NODE GITLAB_NODE_1 GITLAB_NODE_2

  set_node_layout

  if [[ "${SKIP_PACKAGE_INSTALL:-false}" == "true" ]]; then
    log "跳过主机依赖安装（SKIP_PACKAGE_INSTALL=true）"
    require_cmd tar
  else
    pkg_mgr="$(detect_pkg_mgr)"
    install_base_packages "${pkg_mgr}"
  fi

  install_docker "${pkg_mgr}"
  mount_nfs

  if inspect_node_state; then
    log "未发现需要清理的历史状态: ${NODE_NAME}"
    return 0
  fi

  stop_and_remove_containers
  backup_persistent_data
  cleanup_persistent_data

  log "节点初始化清理完成: ${NODE_NAME}"
}

main "$@"

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

usage() {
  cat <<'EOF'
用法:
  sudo bash scripts/prepare-host.sh node29
  sudo bash scripts/prepare-host.sh node25
  sudo bash scripts/prepare-host.sh node26
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
  # 如果设置了 SKIP_NFS_MOUNT=true，完全跳过 NFS 相关操作
  if [[ "${SKIP_NFS_MOUNT:-false}" == "true" ]]; then
    log "跳过 NFS 挂载（SKIP_NFS_MOUNT=true）"
    # 验证挂载点目录是否存在
    if [[ ! -d "${NFS_MOUNT}" ]]; then
      fail "NFS 挂载点目录不存在: ${NFS_MOUNT}，请先手动创建或挂载"
    fi
    log "NFS 挂载点已就绪: ${NFS_MOUNT}"
    return 0
  fi

  mkdir -p "${NFS_MOUNT}"

  if mountpoint -q "${NFS_MOUNT}"; then
    log "NFS 挂载点已就绪: ${NFS_MOUNT}"
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

copy_gitlab_shared_identity() {
  local config_dir="$1"
  local common_dir="${NFS_MOUNT}/gitlab/common"
  local file

  mkdir -p "${common_dir}"

  for file in \
    gitlab-secrets.json \
    ssh_host_ecdsa_key \
    ssh_host_ecdsa_key.pub \
    ssh_host_ed25519_key \
    ssh_host_ed25519_key.pub \
    ssh_host_rsa_key \
    ssh_host_rsa_key.pub; do
    if [[ -f "${common_dir}/${file}" ]]; then
      cp -f "${common_dir}/${file}" "${config_dir}/${file}"
    fi
  done

  ensure_permissions "${config_dir}/gitlab-secrets.json" 600
  ensure_permissions "${config_dir}/ssh_host_ecdsa_key" 600
  ensure_permissions "${config_dir}/ssh_host_ed25519_key" 600
  ensure_permissions "${config_dir}/ssh_host_rsa_key" 600
  ensure_permissions "${config_dir}/ssh_host_ecdsa_key.pub" 644
  ensure_permissions "${config_dir}/ssh_host_ed25519_key.pub" 644
  ensure_permissions "${config_dir}/ssh_host_rsa_key.pub" 644
}

render_redis_conf() {
  local target="$1"
  local mode="$2"
  local node_ip="$3"

  cat > "${target}" <<EOF
bind 0.0.0.0
protected-mode no
port ${REDIS_PORT}
dir /data
appendonly yes
appendfsync everysec
save 900 1
save 300 10
save 60 10000
loglevel notice
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}
replica-read-only yes
replica-announce-ip ${node_ip}
replica-announce-port ${REDIS_PORT}
EOF

  if [[ "${mode}" == "replica" ]]; then
    cat >> "${target}" <<EOF
replicaof ${GITLAB_NODE_1} ${REDIS_PORT}
EOF
  fi

  chmod 600 "${target}"
}

render_sentinel_conf() {
  local target="$1"
  local announce_ip="$2"

  cat > "${target}" <<EOF
bind 0.0.0.0
protected-mode no
port ${SENTINEL_PORT}
dir /data
sentinel monitor ${REDIS_MASTER_NAME} ${GITLAB_NODE_1} ${REDIS_PORT} 2
sentinel auth-pass ${REDIS_MASTER_NAME} ${REDIS_PASSWORD}
sentinel down-after-milliseconds ${REDIS_MASTER_NAME} 5000
sentinel failover-timeout ${REDIS_MASTER_NAME} 60000
sentinel parallel-syncs ${REDIS_MASTER_NAME} 1
sentinel announce-ip ${announce_ip}
sentinel announce-port ${SENTINEL_PORT}
EOF

  chmod 600 "${target}"
}

render_postgresql_conf() {
  local target="$1"

  cat > "${target}" <<EOF
listen_addresses = '*'
port = ${POSTGRES_PORT}
max_connections = ${POSTGRES_MAX_CONNECTIONS}
shared_buffers = '${POSTGRES_SHARED_BUFFERS}'
wal_level = replica
password_encryption = 'scram-sha-256'
hba_file = '/etc/postgresql/pg_hba.conf'
EOF

  chmod 644 "${target}"
}

render_postgresql_hba_conf() {
  local target="$1"

  cat > "${target}" <<EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
host    all             all             ${GITLAB_NODE_1}/32     scram-sha-256
host    all             all             ${GITLAB_NODE_2}/32     scram-sha-256
host    all             all             ${DB_NODE}/32           scram-sha-256
EOF

  chmod 644 "${target}"
}

ensure_gitlab_shared_storage_permissions() {
  local mode="${GITLAB_SHARED_STORAGE_MODE:-2777}"
  local path

  for path in "$@"; do
    [[ -d "${path}" ]] || fail "GitLab 共享目录不存在: ${path}"
    chmod "${mode}" "${path}" || fail "设置 GitLab 共享目录权限失败: ${path}"
  done
}

render_gitlab_rb() {
  local target="$1"
  local auto_migrate="$2"

  cat > "${target}" <<EOF
external_url '${GITLAB_EXTERNAL_URL}'

letsencrypt['enable'] = false
nginx['listen_port'] = ${GITLAB_LISTEN_PORT}
nginx['listen_https'] = ${GITLAB_LISTEN_HTTPS}

postgresql['enable'] = false
gitlab_rails['db_adapter'] = 'postgresql'
gitlab_rails['db_encoding'] = 'unicode'
gitlab_rails['db_host'] = '${DB_NODE}'
gitlab_rails['db_port'] = ${POSTGRES_PORT}
gitlab_rails['db_username'] = '${POSTGRES_USER}'
gitlab_rails['db_password'] = '${POSTGRES_PASSWORD}'

redis['enable'] = false
redis['master_name'] = '${REDIS_MASTER_NAME}'
redis['master_password'] = '${REDIS_PASSWORD}'
gitlab_rails['redis_sentinels'] = [
  { 'host' => '${GITLAB_NODE_1}', 'port' => ${SENTINEL_PORT} },
  { 'host' => '${GITLAB_NODE_2}', 'port' => ${SENTINEL_PORT} },
  { 'host' => '${DB_NODE}', 'port' => ${SENTINEL_PORT} }
]

gitlab_rails['auto_migrate'] = ${auto_migrate}
gitlab_rails['initial_root_password'] = '${GITLAB_ROOT_PASSWORD}'
gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT}

gitlab_rails['shared_path'] = '/mnt/gitlab-shared/shared'
gitlab_rails['uploads_directory'] = '/mnt/gitlab-shared/uploads'
gitlab_rails['artifacts_path'] = '/mnt/gitlab-shared/artifacts'
gitlab_rails['lfs_storage_path'] = '/mnt/gitlab-shared/lfs-objects'
gitlab_rails['packages_storage_path'] = '/mnt/gitlab-shared/packages'
gitlab_rails['dependency_proxy_storage_path'] = '/mnt/gitlab-shared/dependency-proxy'
gitlab_rails['terraform_state_storage_path'] = '/mnt/gitlab-shared/terraform-state'
gitlab_rails['backup_path'] = '/mnt/gitlab-shared/backups'
gitlab_rails['ci_secure_files_storage_path'] = '/mnt/gitlab-shared/ci-secure-files'

gitaly['configuration'] = {
  storage: [
    {
      name: 'default',
      path: '/mnt/gitlab-shared/repositories',
    },
  ],
}

high_availability['mountpoint'] = '/mnt/gitlab-shared'

puma['worker_processes'] = ${GITLAB_PUMA_WORKERS}
sidekiq['concurrency'] = ${GITLAB_SIDEKIQ_CONCURRENCY}

registry['enable'] = false
prometheus_monitoring['enable'] = false
alertmanager['enable'] = false
node_exporter['enable'] = false
redis_exporter['enable'] = false
postgres_exporter['enable'] = false
gitlab_exporter['enable'] = false
EOF

  if [[ -n "${GITLAB_TRUSTED_PROXIES:-}" ]]; then
    cat >> "${target}" <<EOF

gitlab_rails['trusted_proxies'] = %w(${GITLAB_TRUSTED_PROXIES})
EOF
  fi

  chmod 600 "${target}"
}

prepare_node29() {
  mkdir -p \
    "${NFS_MOUNT}/postgresql/data" \
    "${NFS_MOUNT}/postgresql/conf" \
    "${NFS_MOUNT}/redis/sentinel-node29"

  render_postgresql_conf "${NFS_MOUNT}/postgresql/conf/postgresql.conf"
  render_postgresql_hba_conf "${NFS_MOUNT}/postgresql/conf/pg_hba.conf"
  render_sentinel_conf "${NFS_MOUNT}/redis/sentinel-node29/sentinel.conf" "${DB_NODE}"
}

prepare_gitlab_node() {
  local node_name="$1"
  local node_ip="$2"
  local redis_mode="$3"
  local auto_migrate="$4"
  local redis_dir="${NFS_MOUNT}/redis/${node_name}"
  local sentinel_dir="${NFS_MOUNT}/redis/sentinel-${node_name}"
  local gitlab_dir="${NFS_MOUNT}/gitlab/${node_name}"
  local gitlab_shared_dir="${NFS_MOUNT}/gitlab/shared"

  mkdir -p \
    "${redis_dir}" \
    "${redis_dir}/appendonlydir" \
    "${sentinel_dir}" \
    "${gitlab_dir}/config" \
    "${gitlab_dir}/logs" \
    "${gitlab_dir}/data" \
    "${NFS_MOUNT}/gitlab/common" \
    "${gitlab_shared_dir}/shared" \
    "${gitlab_shared_dir}/uploads" \
    "${gitlab_shared_dir}/artifacts" \
    "${gitlab_shared_dir}/lfs-objects" \
    "${gitlab_shared_dir}/packages" \
    "${gitlab_shared_dir}/dependency-proxy" \
    "${gitlab_shared_dir}/terraform-state" \
    "${gitlab_shared_dir}/backups" \
    "${gitlab_shared_dir}/ci-secure-files" \
    "${gitlab_shared_dir}/repositories"

  # Gitaly/Workhorse 等服务会直接在共享卷根目录下创建子目录。
  # 这里在宿主机侧预先放宽目录权限，避免 NFS/root_squash 下容器用户无法首次写入。
  ensure_gitlab_shared_storage_permissions \
    "${gitlab_shared_dir}/shared" \
    "${gitlab_shared_dir}/uploads" \
    "${gitlab_shared_dir}/artifacts" \
    "${gitlab_shared_dir}/lfs-objects" \
    "${gitlab_shared_dir}/packages" \
    "${gitlab_shared_dir}/dependency-proxy" \
    "${gitlab_shared_dir}/terraform-state" \
    "${gitlab_shared_dir}/backups" \
    "${gitlab_shared_dir}/ci-secure-files" \
    "${gitlab_shared_dir}/repositories"

  copy_gitlab_shared_identity "${gitlab_dir}/config"
  render_redis_conf "${redis_dir}/redis.conf" "${redis_mode}" "${node_ip}"
  render_sentinel_conf "${sentinel_dir}/sentinel.conf" "${node_ip}"
  render_gitlab_rb "${gitlab_dir}/config/gitlab.rb" "${auto_migrate}"
}

main() {
  local pkg_mgr=""

  case "${NODE_NAME}" in
    node29|node25|node26) ;;
    *)
      usage
      fail "未知节点标识: ${NODE_NAME:-<empty>}"
      ;;
  esac

  require_root
  require_env \
    NFS_SERVER NFS_EXPORT NFS_MOUNT \
    DB_NODE GITLAB_NODE_1 GITLAB_NODE_2 \
    POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
    REDIS_PORT REDIS_PASSWORD REDIS_MASTER_NAME SENTINEL_PORT \
    GITLAB_EXTERNAL_URL GITLAB_ROOT_PASSWORD GITLAB_SSH_PORT \
    GITLAB_PUMA_WORKERS GITLAB_SIDEKIQ_CONCURRENCY \
    GITLAB_LISTEN_PORT GITLAB_LISTEN_HTTPS

  if [[ "${SKIP_PACKAGE_INSTALL:-false}" == "true" ]]; then
    log "跳过主机依赖安装（SKIP_PACKAGE_INSTALL=true）"
    require_cmd tar
  else
    pkg_mgr="$(detect_pkg_mgr)"
    install_base_packages "${pkg_mgr}"
  fi

  install_docker "${pkg_mgr}"
  mount_nfs

  case "${NODE_NAME}" in
    node29)
      prepare_node29
      ;;
    node25)
      prepare_gitlab_node node25 "${GITLAB_NODE_1}" primary true
      ;;
    node26)
      prepare_gitlab_node node26 "${GITLAB_NODE_2}" replica false
      ;;
  esac

  log "节点准备完成: ${NODE_NAME}"
}

main "$@"

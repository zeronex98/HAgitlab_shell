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
GITLAB_CHECK_URL="${GITLAB_CHECK_URL:-http://127.0.0.1:${GITLAB_BACKEND_HTTP_PORT}/-/readiness}"
BOOTSTRAP_MAX_ATTEMPTS="${BOOTSTRAP_MAX_ATTEMPTS:-180}"
BOOTSTRAP_INTERVAL_SECONDS="${BOOTSTRAP_INTERVAL_SECONDS:-10}"

usage() {
  cat <<'EOF'
用法:
  sudo bash scripts/bootstrap-primary.sh node25
EOF
}

required_identity_files() {
  cat <<'EOF'
gitlab-secrets.json
ssh_host_ecdsa_key
ssh_host_ecdsa_key.pub
ssh_host_ed25519_key
ssh_host_ed25519_key.pub
ssh_host_rsa_key
ssh_host_rsa_key.pub
EOF
}

missing_identity_files() {
  local source_dir="$1"
  local file

  while read -r file; do
    if [[ ! -f "${source_dir}/${file}" ]]; then
      printf '%s\n' "${file}"
    fi
  done < <(required_identity_files)
}

print_gitlab_diagnostics() {
  local source_dir="${NFS_MOUNT}/gitlab/node25/config"

  log "node25 公共密钥文件仍未就绪，打印诊断信息"
  log "当前配置目录: ${source_dir}"

  if command -v docker >/dev/null 2>&1; then
    docker ps -a --filter "name=^/gitlab-node25$" >&2 || true
    docker logs --tail 200 gitlab-node25 >&2 || true
  fi

  if [[ -d "${NFS_MOUNT}/gitlab/node25/logs" ]]; then
    find "${NFS_MOUNT}/gitlab/node25/logs" -maxdepth 2 -type f | sort >&2 || true
  fi

  curl -fsS "${GITLAB_CHECK_URL}" >&2 || true
}

wait_for_identity_files() {
  local source_dir="${NFS_MOUNT}/gitlab/node25/config"
  local attempt=0
  local missing=()
  local missing_display=""

  while true; do
    mapfile -t missing < <(missing_identity_files "${source_dir}")
    if (( ${#missing[@]} == 0 )); then
      return 0
    fi

    attempt=$((attempt + 1))

    if (( attempt == 1 || attempt % 6 == 0 )); then
      missing_display="$(printf '%s ' "${missing[@]}")"
      log "等待 node25 生成公共密钥与密文（第 ${attempt}/${BOOTSTRAP_MAX_ATTEMPTS} 次），缺少: ${missing_display% }"
    fi

    if (( attempt >= BOOTSTRAP_MAX_ATTEMPTS )); then
      print_gitlab_diagnostics
      fail "node25 在预期时间内未生成公共密钥与密文: ${source_dir}"
    fi

    sleep "${BOOTSTRAP_INTERVAL_SECONDS}"
  done
}

sync_common_identity() {
  local source_dir="${NFS_MOUNT}/gitlab/node25/config"
  local target_dir="${NFS_MOUNT}/gitlab/common"
  local file

  mkdir -p "${target_dir}"

  for file in \
    gitlab-secrets.json \
    ssh_host_ecdsa_key \
    ssh_host_ecdsa_key.pub \
    ssh_host_ed25519_key \
    ssh_host_ed25519_key.pub \
    ssh_host_rsa_key \
    ssh_host_rsa_key.pub; do
    [[ -f "${source_dir}/${file}" ]] || fail "缺少文件: ${source_dir}/${file}"
    cp "${source_dir}/${file}" "${target_dir}/${file}"
  done

  ensure_permissions "${target_dir}/gitlab-secrets.json" 600
  ensure_permissions "${target_dir}/ssh_host_ecdsa_key" 600
  ensure_permissions "${target_dir}/ssh_host_ed25519_key" 600
  ensure_permissions "${target_dir}/ssh_host_rsa_key" 600
  ensure_permissions "${target_dir}/ssh_host_ecdsa_key.pub" 644
  ensure_permissions "${target_dir}/ssh_host_ed25519_key.pub" 644
  ensure_permissions "${target_dir}/ssh_host_rsa_key.pub" 644
}

main() {
  if [[ "${NODE_NAME}" != "node25" ]]; then
    usage
    fail "bootstrap-primary 只允许在 node25 上执行"
  fi

  require_root
  require_env NFS_MOUNT GITLAB_BACKEND_HTTP_PORT
  wait_for_identity_files
  sync_common_identity
  if curl -fsS "${GITLAB_CHECK_URL}" >/dev/null 2>&1; then
    log "node25 已就绪，并已导出 GitLab 公共密钥与密文到 ${NFS_MOUNT}/gitlab/common"
  else
    log "node25 尚未通过 readiness，但公共密钥与密文已导出到 ${NFS_MOUNT}/gitlab/common"
  fi
}

main "$@"

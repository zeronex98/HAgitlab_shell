#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_NODE="${1:-all}"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
用法:
  bash scripts/check-status.sh
  bash scripts/check-status.sh all
  bash scripts/check-status.sh node29
  bash scripts/check-status.sh node25
  bash scripts/check-status.sh node26
EOF
}

case "${TARGET_NODE}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

[[ -f "${ROOT_DIR}/inventory.env" ]] || fail "缺少 ${ROOT_DIR}/inventory.env"
# shellcheck source=../inventory.env
source "${ROOT_DIR}/inventory.env"

require_local_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少本地命令: $1"
}

remote_target() {
  local host="$1"
  printf '%s@%s' "${SSH_USER}" "${host}"
}

ssh_opts() {
  printf '%s' "-p ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
}

run_remote_check() {
  local host="$1"
  local node_name="$2"
  local target
  local remote_cmd

  target="$(remote_target "${host}")"
  printf -v remote_cmd 'sudo bash -s -- %q %q %q' "${node_name}" "${NFS_MOUNT}" "${GITLAB_BACKEND_HTTP_PORT}"

  ssh $(ssh_opts) "${target}" "${remote_cmd}" <<'EOF'
node_name="$1"
nfs_mount="$2"
gitlab_backend_http_port="$3"
status_code=0

print_item() {
  local label="$1"
  local value="$2"
  printf '  %-20s %s\n' "${label}" "${value}"
}

mark_fail() {
  status_code=1
}

check_container() {
  local container="$1"
  local require_healthy="$2"
  local state
  local health

  if ! docker container inspect "${container}" >/dev/null 2>&1; then
    print_item "container:${container}" "missing"
    mark_fail
    return
  fi

  state="$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || echo unknown)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}" 2>/dev/null || echo unknown)"
  print_item "container:${container}" "${state} / ${health}"

  if [[ "${state}" != "running" ]]; then
    mark_fail
    return
  fi

  if [[ "${require_healthy}" == "true" && "${health}" != "healthy" ]]; then
    mark_fail
  fi
}

check_dir() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    print_item "dir:${path}" "present"
  else
    print_item "dir:${path}" "missing"
    mark_fail
  fi
}

check_mount_dir() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    if mountpoint -q "${path}" >/dev/null 2>&1; then
      print_item "mount:${path}" "mounted"
    else
      print_item "mount:${path}" "dir-only"
    fi
  else
    print_item "mount:${path}" "missing"
    mark_fail
  fi
}

check_identity_dir() {
  local dir="$1"
  local label="$2"
  local file
  local missing=()

  for file in \
    gitlab-secrets.json \
    ssh_host_ecdsa_key \
    ssh_host_ecdsa_key.pub \
    ssh_host_ed25519_key \
    ssh_host_ed25519_key.pub \
    ssh_host_rsa_key \
    ssh_host_rsa_key.pub; do
    [[ -f "${dir}/${file}" ]] || missing+=("${file}")
  done

  if (( ${#missing[@]} == 0 )); then
    print_item "${label}" "ok"
    return
  fi

  print_item "${label}" "missing: ${missing[*]}"
  mark_fail
}

check_gitlab_readiness() {
  local url="http://127.0.0.1:${gitlab_backend_http_port}/-/readiness"

  if ! command -v curl >/dev/null 2>&1; then
    print_item "gitlab:readiness" "curl missing"
    mark_fail
    return
  fi

  if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
    print_item "gitlab:readiness" "ok"
  else
    print_item "gitlab:readiness" "failed"
    mark_fail
  fi
}

printf '== %s ==\n' "${node_name}"
check_mount_dir "${nfs_mount}"

case "${node_name}" in
  node29)
    check_container postgres-node29 true
    check_container redis-sentinel-node29 true
    check_dir "${nfs_mount}/postgresql/data"
    check_dir "${nfs_mount}/postgresql/conf"
    ;;
  node25)
    check_container redis-node25 true
    check_container redis-sentinel-node25 true
    check_container gitlab-node25 false
    check_gitlab_readiness
    check_identity_dir "${nfs_mount}/gitlab/node25/config" "identity:node25"
    check_identity_dir "${nfs_mount}/gitlab/common" "identity:common"
    check_dir "${nfs_mount}/gitlab/shared/repositories"
    ;;
  node26)
    check_container redis-node26 true
    check_container redis-sentinel-node26 true
    check_container gitlab-node26 false
    check_gitlab_readiness
    check_identity_dir "${nfs_mount}/gitlab/node26/config" "identity:node26"
    check_identity_dir "${nfs_mount}/gitlab/common" "identity:common"
    check_dir "${nfs_mount}/gitlab/shared/repositories"
    ;;
  *)
    print_item "error" "unknown node"
    status_code=1
    ;;
esac

if (( status_code == 0 )); then
  print_item "result" "OK"
else
  print_item "result" "FAIL"
fi

exit "${status_code}"
EOF
}

NODE_NAMES=()
NODE_HOSTS=()
NODE_OUTPUTS=()
NODE_PIDS=()

queue_node() {
  NODE_NAMES+=("$1")
  NODE_HOSTS+=("$2")
}

select_nodes() {
  case "${TARGET_NODE}" in
    all)
      queue_node node29 "${DB_NODE}"
      queue_node node25 "${GITLAB_NODE_1}"
      queue_node node26 "${GITLAB_NODE_2}"
      ;;
    node29)
      queue_node node29 "${DB_NODE}"
      ;;
    node25)
      queue_node node25 "${GITLAB_NODE_1}"
      ;;
    node26)
      queue_node node26 "${GITLAB_NODE_2}"
      ;;
    *)
      usage
      fail "未知检查目标: ${TARGET_NODE}"
      ;;
  esac
}

spawn_check() {
  local node_name="$1"
  local host="$2"
  local output_file="$3"

  (
    printf 'host: %s\n' "${host}"
    run_remote_check "${host}" "${node_name}"
  ) >"${output_file}" 2>&1 &
  NODE_PIDS+=("$!")
}

main() {
  local overall_status=0
  local tmp_dir
  local index

  require_local_bin ssh
  require_env SSH_USER SSH_PORT DB_NODE GITLAB_NODE_1 GITLAB_NODE_2 NFS_MOUNT GITLAB_BACKEND_HTTP_PORT
  select_nodes

  tmp_dir="$(mktemp -d)"
  trap "rm -rf '${tmp_dir}'" EXIT

  for index in "${!NODE_NAMES[@]}"; do
    NODE_OUTPUTS[index]="${tmp_dir}/${NODE_NAMES[index]}.log"
    spawn_check "${NODE_NAMES[index]}" "${NODE_HOSTS[index]}" "${NODE_OUTPUTS[index]}"
  done

  for index in "${!NODE_PIDS[@]}"; do
    if ! wait "${NODE_PIDS[index]}"; then
      overall_status=1
    fi
  done

  for index in "${!NODE_OUTPUTS[@]}"; do
    cat "${NODE_OUTPUTS[index]}"
  done

  if (( overall_status == 0 )); then
    log "服务状态检查通过"
  else
    log "服务状态检查失败"
  fi

  exit "${overall_status}"
}

main "$@"

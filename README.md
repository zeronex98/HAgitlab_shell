# GitLab Docker HA Deployment Bundle

这个目录提供了基于你给定 3 台节点的 GitLab Docker 部署包：

- `27.204.101.25`：GitLab + Redis + Redis Sentinel
- `27.204.101.26`：GitLab + Redis + Redis Sentinel
- `27.204.101.29`：PostgreSQL + Redis Sentinel，复用现有 NFS 服务

## 先说明清楚的约束

1. 当前拓扑下，`27.204.101.29` 上只有单台 PostgreSQL，因此数据库层仍然是单点，不能称为完整 HA。
2. GitLab 官方明确要求 Gitaly 使用本地磁盘，不支持把仓库数据放在 NFS 上。本部署包为了满足你提出的 `/data/gitlab` 持久化约束，将仓库路径也放到 NFS；这属于“可运行但不受官方支持”的折中方案。
3. 两台 GitLab 节点需要前置一个统一入口，例如 F5、SLB、HAProxy、Nginx 或 VIP，`GITLAB_EXTERNAL_URL` 必须指向这个统一入口。
4. 如果当前只能用 IP 访问，没有 VIP/LB，那么两台 GitLab 节点都先统一写 `http://27.204.101.25` 作为 `GITLAB_EXTERNAL_URL`，不要让 node26 写成自己的 IP。
5. NFS 导出如果启用了 `root_squash`，GitLab/PostgreSQL/Redis 容器通常会因为权限问题初始化失败；至少需要保证三台节点对 `/data/gitlab` 具备可写权限，并能满足容器运行用户的 UID/GID 映射。
6. 如果 `NFS_SERVER` 本身就是部署节点，且导出目录已经是该机本地目录，`prepare-host.sh` 会自动改用 `bind mount`，避免节点对自己再次发起 NFS 挂载。
7. 这个部署包默认保留宿主机 SSH `22` 给系统管理，GitLab SSH 改为容器内 `22` 映射到宿主机 `2222`；负载均衡器需要把外部 Git SSH 流量转发到两台 GitLab 节点的 `2222`。

## 目录

- `inventory.env.example`：变量模板
- `compose/node29/docker-compose.yml`：NFS/DB 节点编排
- `compose/node25/docker-compose.yml`：GitLab 节点 25 编排
- `compose/node26/docker-compose.yml`：GitLab 节点 26 编排
- `scripts/init-node.sh`：检查旧容器与持久化目录，按需备份并清理
- `scripts/prepare-host.sh`：安装 Docker、挂载 NFS、渲染配置
- `scripts/deploy-node.sh`：单节点拉起容器
- `scripts/bootstrap-primary.sh`：从 node25 同步 GitLab 公共密钥和密文
- `scripts/check-status.sh`：通过 SSH 快速检查三台节点的容器、readiness 和关键目录状态
- `scripts/deploy-all.sh`：从当前目录通过 SSH 顺序部署三台机器

## 使用方式

1. 复制变量模板并填写：

```bash
cp inventory.env.example inventory.env
```

2. 重点修改这些变量：

- `SSH_USER`
- `GITLAB_EXTERNAL_URL`
- `POSTGRES_PASSWORD`
- `REDIS_PASSWORD`
- `GITLAB_ROOT_PASSWORD`
- 需要收紧 NFS 共享目录权限时，再调整 `GITLAB_SHARED_STORAGE_MODE`
- 需要关闭初始化前的数据备份时，再调整 `INIT_BACKUP_ENABLED`
- 需要修改初始化备份目录时，再调整 `INIT_BACKUP_ROOT`
- 离线环境下加上 `SKIP_DOCKER_PULL=true`
- 如果目标机已经具备 `tar`、`docker`、`docker compose`，并且不希望脚本再执行 `apt/yum/dnf`，再加上 `SKIP_PACKAGE_INSTALL=true`
- 如果需要改后端端口，再调整 `GITLAB_BACKEND_HTTP_PORT`、`GITLAB_BACKEND_SSH_PORT`

其中 `GITLAB_EXTERNAL_URL` 的规则是：

- 有 `VIP / LB IP` 时，写统一入口 IP
- 没有 `VIP / LB IP` 时，两台节点都统一写 `http://27.204.101.25`

3. 确保当前机器可以免密 SSH 到三台节点，并且远端具备 `sudo` 权限。

4. 直接执行：

```bash
bash scripts/deploy-all.sh
```

部署完成后，或排查异常时，可以快速检查状态：

```bash
bash scripts/check-status.sh
```

也可以只检查单个节点：

```bash
bash scripts/check-status.sh node25
```

脚本会并发检查三台节点；任意节点存在容器未运行、readiness 失败、公共密钥缺失或关键目录不存在时，会返回非 0。

5. 部署顺序会自动按下面执行：

- `27.204.101.29`、`27.204.101.25`、`27.204.101.26`：先同步脚本，并执行初始化检查
- 初始化时如果发现旧容器或持久化目录仍有文件，会先停止旧容器、仅备份持久化目录数据，然后清理旧状态
- `27.204.101.29`：准备环境并启动 PostgreSQL + Sentinel
- `27.204.101.25`：准备环境并启动 Redis + Sentinel + GitLab
- `27.204.101.25`：等待 GitLab 首次初始化，导出 `gitlab-secrets.json` 与 SSH host key
- `27.204.101.26`：准备环境并导入公共密钥后启动 Redis + Sentinel + GitLab

## PostgreSQL 配置落盘

- `prepare-host.sh node29` 会把 PostgreSQL 配置写到 `${NFS_MOUNT}/postgresql/conf/postgresql.conf` 和 `${NFS_MOUNT}/postgresql/conf/pg_hba.conf`。
- `compose/node29/docker-compose.yml` 会把这个目录挂载到容器 `/etc/postgresql`，因此 `listen_addresses`、`pg_hba`、连接数和缓存配置不会因容器重建丢失。
- `deploy-node.sh node29` 会等待 `postgres-node29` 通过健康检查；如果容器异常退出，会直接打印最近 200 行日志，方便排查重启原因。

## GitLab 共享目录权限

- `prepare-host.sh node25|node26` 会对 `${NFS_MOUNT}/gitlab/shared/*` 预设目录权限，默认使用 `GITLAB_SHARED_STORAGE_MODE=2777`。
- 这样做是为了解决 Gitaly 在共享卷上首次创建 `repositories/+gitaly` 时的 `permission denied`，尤其是在 NFS `root_squash` 或 UID/GID 映射不稳定的情况下。
- 如果你已经明确掌握容器运行用户的 UID/GID，并希望更严格，可以把 `GITLAB_SHARED_STORAGE_MODE` 改成例如 `2775` 后重新执行 `prepare-host.sh`。

## 初始化与备份

- `init-node.sh` 会先检查节点上是否存在历史容器，或持久化目录中是否已有文件。
- 如果存在旧状态，会先停止并移除该节点旧容器，再把持久化目录备份到 `INIT_BACKUP_ROOT/<时间戳>/`。
- 初始化备份只包含 PostgreSQL、Redis、GitLab 的持久化目录与配置数据，不会执行 `docker save`，也不会导出 Docker 镜像文件保存。
- 备份完成后，脚本会清空旧持久化目录，再进入正式部署。

## 手动分节点执行

如果你不想使用 `deploy-all.sh`，也可以把整个目录拷到各节点后单独执行：

```bash
sudo bash scripts/init-node.sh node29
sudo bash scripts/prepare-host.sh node29
sudo bash scripts/deploy-node.sh node29

sudo bash scripts/init-node.sh node25
sudo bash scripts/prepare-host.sh node25
sudo bash scripts/deploy-node.sh node25
sudo bash scripts/bootstrap-primary.sh node25

sudo bash scripts/init-node.sh node26
sudo bash scripts/prepare-host.sh node26
sudo bash scripts/deploy-node.sh node26
```

## 端口

- GitLab 节点宿主机：`22/tcp`、默认 `8080/tcp`、默认 `2222/tcp`、`6379/tcp`、`26379/tcp`
- PostgreSQL 节点：`5432/tcp`、`26379/tcp`
- NFS：按你现有服务开放

## 建议的后续补强

1. PostgreSQL 至少增加一台副本节点，再引入 Patroni/repmgr 或托管数据库。
2. 仓库存储改为本地 SSD，并用 Gitaly Cluster/Praefect 做真正的 GitLab 仓库高可用。
3. 在负载均衡器上为 `/-/readiness` 配置健康检查。

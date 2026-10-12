# Archinfra Elasticsearch Logging Stack

**v0.2.1 — 自维护 Helm Chart + 离线单文件 `.run`，完全不使用 ECK Operator。**

适用于 Archinfra 中间件私有化交付。组件包括 Elasticsearch 9.5.5、Kibana 9.5.5、Fluent Bit 5.1.3、elasticsearch-exporter 1.11.0 和启动时权限初始化所需 curl 8.16.0。

## 交付范围

| 模块 | Kubernetes 资源 | 默认行为 |
| --- | --- | --- |
| Elasticsearch | StatefulSet + PVC + ClusterIP/Headless Service | 1 节点；`--mode ha` 为 3 节点 |
| Kibana | Deployment + ClusterIP Service | 开启，内部 HTTP，连 ES 使用 HTTPS + CA |
| Fluent Bit | DaemonSet + ConfigMap + RBAC | 开启，CRI 日志、K8s 元数据、HTTPS、5G/节点缓冲上限 |
| Elasticsearch Exporter | Deployment + Service | 开启，独立监控账号，Prometheus 9114 |
| 安全与初始化 | Auth Secret、TLS Secret、Helm pre-upgrade Job | 随机密码、TLS CA/证书、最小权限用户 |
| 索引管理 | Elasticsearch API Job | logs-k8s-* 模板、默认 14 天 ILM |
| 监控发现 | ServiceMonitor / PrometheusRule（仅 CRD 已存在时） | 自动接入 Archinfra 的监控标签 |

没有 Operator、没有自定义 CRD；不会安装 ECK，也不会要求最终环境拥有 `jq`、Python 或 curl。

安装包面向**已有 Kubernetes、持久化 StorageClass 和内网镜像仓库**的环境，不会安装这三类基础设施，也不会安装 Prometheus/Grafana。

本文命令均在 **Linux Bash** 中执行；Windows 用户可通过 SSH 登录 Linux 管理机操作。默认 release 为 `elasticsearch`、namespace 为 `logging`；使用自定义名称时，后文资源名需要同步替换。

快速路径：**下载校验 → 检查集群和仓库 → 选择单节点/三节点安装 → 打开 Kibana → 创建数据视图 → 生成测试日志验证链路**。详细操作见下文。

## 构建和产物

### 直接下载已验证的离线包

2026-10-12 的 [v0.2.1 双架构构建](https://github.com/archinfra/apps_elasticsearch/actions/runs/38190071339)已成功：

- [amd64 Artifact ZIP](https://github.com/archinfra/apps_elasticsearch/actions/runs/38190071339/artifacts/11721626712)
- [arm64 Artifact ZIP](https://github.com/archinfra/apps_elasticsearch/actions/runs/38190071339/artifacts/11720709045)
- [修复 PR](https://github.com/archinfra/apps_elasticsearch/pull/1)，合并状态以页面为准。

Artifact 保留 14 天，下载需要 GitHub 登录及相应权限；过期后重新构建。此版本没有发布永久 Release。选择架构时看**目标 Kubernetes 工作节点**，不是下载电脑的架构。

将 ZIP 传到 Linux 管理机，在新目录中解压（文件名以实际下载为准）：

```bash
unzip elasticsearch-offline-amd64.zip
sha256sum -c elasticsearch-installer-v0.2.1-amd64.run.sha256
chmod +x elasticsearch-installer-v0.2.1-amd64.run
./elasticsearch-installer-v0.2.1-amd64.run help
```

校验应显示 `OK`；arm64 替换对应 ZIP、`.run` 和 `.sha256` 文件名。**构建通过不等于真实 K8s 部署验收完成**，还需执行后文的日志链路验证。

### 自行构建

构建机需要：bash、Docker、Python 3、tar、sha256sum。GitHub Actions 分别构建两个架构，真正下载和打包官方容器镜像。

v0.2.1 修复 Fluent Bit 缓冲上限配置位置，并增加交付门禁：使用原生 amd64/arm64 Runner 校验实际 Fluent Bit 镜像配置，确认旧错误配置被拒绝；读取成品 `.run` 内的五个镜像归档，核验平台、标签、镜像层和离线索引。全部通过后才上传 Artifact。手动构建可在 Actions → Build Offline Run → Run workflow 中发起。

本地构建后的同等验证（另需 Helm、OpenSSL）：

```bash
bash tests/fluentbit-runtime.sh amd64
python3 tests/verify-payload.py dist/elasticsearch-installer-v0.2.1-amd64.run --arch amd64
(cd dist && sha256sum -c *.sha256)
```

运行镜像检查需要与镜像匹配的 CPU 架构；检查 arm64 时在原生 arm64 构建机执行并替换上述参数。详细排错见 `docs/BUILD_VALIDATION.md`。

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
# 或 build.sh --arch all
```

产物：

```text
dist/elasticsearch-installer-v0.2.1-amd64.run
dist/elasticsearch-installer-v0.2.1-amd64.run.sha256
dist/elasticsearch-installer-v0.2.1-arm64.run
dist/elasticsearch-installer-v0.2.1-arm64.run.sha256
```

每个 `.run` 内包含 Helm Chart、对应 CPU 架构的五个镜像 tar、`images/index.tsv` 和安装逻辑，不包含 Helm/kubectl 可执行文件。镜像目标 tag 带 `-amd64` 或 `-arm64`；工作负载的 `nodeSelector` 也限制架构。**当前不创建混合架构 multi-platform manifest**，混合架构 K8s 集群只在与安装包同架构的节点调度本套工作负载。

手动触发 Actions 时选择包含所需改动的分支。普通源码 push 不一定触发打包：现有自动打包入口监视 `ci/build-request.txt`，也支持手动触发；Validate 是独立工作流。

## 安装

客户现场要求：Helm 3、kubectl、bash、tar、od、base64 和常见 GNU 工具；校验使用 sha256sum，解压 ZIP 使用 unzip。CI 使用 Helm 3.19.0。管理机 kubeconfig 必须具备 StatefulSet、Secret、Namespace 等资源以及 Fluent Bit ClusterRole/ClusterRoleBinding 管理权限；已有监控 CRD 时还需要创建相关监控资源的权限。

默认需要管理机提供 Docker daemon 来导入并推送镜像；Worker 可以使用 containerd，不必安装 Docker。若镜像已提前入库，使用 `--skip-image-prepare` 可省去管理机 Docker。

检查当前集群及 StorageClass：

```bash
kubectl config current-context
kubectl get nodes -L kubernetes.io/arch
kubectl get storageclass
helm version --short
docker info
df -h /tmp
docker system df
```

部署前确认：

- 节点不仅 Ready，还需满足 CPU/内存、污点、卷拓扑和调度条件。HA 要求至少 3 台同架构、可调度且资源足够的节点。
- `.run` 会解压到临时目录，Docker 导入也占磁盘；不能只按约 1.5 GB 下载包大小预留空间。可设置 `TMPDIR` 指向较大的可写磁盘。
- 当前模板使用集群域 `cluster.local`；自定义域需要先修改 Chart 并重新构建。
- 命名空间策略应允许 Fluent Bit 使用日志及缓冲 hostPath。
- 首次验证建议使用 `single + lite`。默认实际为 `single + standard`，示例显式覆盖，`ha + lite` 会被拒绝。

**单节点开发环境：**

```bash
./elasticsearch-installer-v0.2.1-amd64.run install \
  --namespace logging \
  --mode single \
  --resource-profile lite \
  --storage-class ceph-rbd \
  -y
```

**三节点日志平台：**

```bash
./elasticsearch-installer-v0.2.1-amd64.run install \
  --namespace logging \
  --mode ha \
  --resource-profile standard \
  --storage-class ceph-rbd \
  --storage-size 100Gi \
  --registry sealos.hub:5000/kube4 \
  --retention-days 14 \
  -y
```

`ceph-rbd` 只是示例。必须选择现场已经验证的持久化块存储，**不使用 NFS 默认值**。三节点模式需要至少三个目标架构 Ready 节点，且确保有足够可调度 Worker 节点。

如果客户的内网 Registry 已经同步五个镜像，可追加 `--skip-image-prepare`；Registry 登录使用 `--registry-user` 和 `--registry-password-file`，不写死任何固定凭据。默认 ClusterIP，不开放 NodePort。

### 内网镜像仓库的配置

`--registry` 是主机与路径前缀，不带 `http://` 或 `https://`，末尾不带 `/`。正常安装执行 `docker load → tag → push → Helm 部署`，不会直接把镜像导入所有节点 containerd。

例如 amd64 默认会推送这五个镜像：

```text
sealos.hub:5000/kube4/elasticsearch:9.5.5-amd64
sealos.hub:5000/kube4/kibana:9.5.5-amd64
sealos.hub:5000/kube4/fluent-bit:5.1.3-amd64
sealos.hub:5000/kube4/curl:8.16.0-amd64
sealos.hub:5000/kube4/elasticsearch-exporter:1.11.0-amd64
```

arm64 使用对应的 `-arm64` 后缀。跳过镜像准备前，确认完整地址和标签一致；即使跳过，也仍需完整 `.run` 并会解包。

有推送认证的仓库，在安装命令中同时增加这两个选项：

```bash
--registry-user YOUR_REGISTRY_USER \
--registry-password-file /secure/registry-password
```

由现场安全提供密码文件并限制其读取权限。**这两个选项只用于管理机 Docker 登录，不会给 Pod 配置 imagePullSecrets。** 节点运行时的拉取认证、仓库 CA/HTTP 信任和 DNS 解析必须提前配置，当前 CLI 没有相关配置参数。

### 为什么安装分两阶段

安装器先使用 Helm 创建 ES StatefulSet 和 TLS Secret，关闭其他组件，等待 ES Ready。然后通过 Helm pre-upgrade Job 调用 Elasticsearch API，创建：

- `kibana_system` 密码；
- `archinfra_log_writer` 仅对 `logs-k8s-*` 的写入权限；
- `archinfra_metrics` 只读监控权限；
- `archinfra-logs-retain` ILM 策略及日志 Index Template。

第二阶段升级 Helm release 启用 Kibana、Fluent Bit、Exporter。这样首次安装时 Kibana 不会因为缺少系统用户密码而阻塞 ES 启动。

每阶段 Helm 等待超时为 20 分钟，后续 rollout 检查为 5 分钟；当前没有 `--wait-timeout` 选项。可在另一终端执行 `kubectl -n logging get pods,pvc,jobs -w` 观察。bootstrap Job 成功后自动删除，失败时通常保留供排错。直接 `helm install` 不能代替安装器的离线镜像准备、Secret 生成和两阶段初始化。

### 完整参数表

| 参数 | 默认值 / 说明 |
| --- | --- |
| `install / status / uninstall / help` | 四个支持的动作 |
| `-n, --namespace` | `logging` |
| `--name` | `elasticsearch` |
| `--mode` | `single / ha`，默认 `single` |
| `--resource-profile` | `lite / standard / large`，默认 `standard` |
| `--storage-class` | install 必填 |
| `--storage-size` | 根据档位选取；正整数 Gi/Ti |
| `--registry` | `sealos.hub:5000/kube4` |
| `--registry-user` / `--registry-password-file` | 可选，必须同时提供 |
| `--skip-image-prepare` | 跳过镜像导入/推送，默认不跳过 |
| `--enable-kibana / --disable-kibana` | 默认开启 |
| `--enable-fluent-bit / --disable-fluent-bit` | 默认开启 |
| `--enable-monitoring / --disable-monitoring` | 默认开启 Exporter 和监控资源 |
| `--retention-days` | `14`，允许 1–3650 |
| `-y, --yes` | 跳过交互确认 |
| `-h, --help` | 帮助 |

namespace/release 名只支持小写字母、数字和中划线，长度上限 40。当前没有 NodePort、Ingress、imagePullSecrets、关闭 TLS、PVC 扩容或单节点转 HA 的安装参数。

### 资源规格（每个 ES Pod）

| 档位 | Request CPU / Memory | Limit CPU / Memory | 默认 PVC | JVM Heap |
| --- | --- | --- | --- | --- |
| lite | 500m / 2Gi | 1C / 4Gi | 30Gi | 2g |
| standard | 1C / 4Gi | 2C / 8Gi | 100Gi | 4g |
| large | 2C / 8Gi | 4C / 16Gi | 300Gi | 8g |

`--mode single` 为一节点非 HA；`--mode ha` 为三节点混合角色，严格跨节点反亲和。这些是初始资源规格，不等于已经验证的容量承诺。

HA 的 ES 资源总量需按每节点乘以 3，另加系统和附加组件开销：Kibana Request 250m/1Gi、Limit 1 CPU/2Gi；Fluent Bit 每节点 Request 50m/128Mi、Limit 500m/512Mi；Exporter Request 50m/64Mi、Limit 250m/256Mi。

## 日常管理

```bash
./elasticsearch-installer-v0.2.1-amd64.run status -n logging
kubectl -n logging get sts,deploy,ds,pods,pvc
kubectl -n logging port-forward svc/elasticsearch-kibana 5601:5601
kubectl -n logging get secret elasticsearch-auth -o jsonpath='{.data.elastic-password}' | base64 -d
```

浏览器访问 `http://127.0.0.1:5601`，用户 `elastic`，密码从 Secret 读取。Kibana 端口转发经 SSH/堡垒机保护，不建议随意直接发布公网入口。

卸载：

```bash
./elasticsearch-installer-v0.2.1-amd64.run uninstall --namespace logging -y
```

默认保留 ES PVC、`<release>-auth` 和 `<release>-tls`。不支持自动毁灭数据的卸载参数。PVC 扩容、迁移 StorageClass、节点数量变更需要专门的变更/备份流程，不允许普通安装覆盖。

## Kibana 怎么用

### 远程管理机访问

保持前文 `kubectl port-forward` 终端运行。若命令执行在远程 Linux 管理机，再从自己电脑建立 SSH 隧道：

```bash
ssh -N -L 5601:127.0.0.1:5601 YOUR_USER@YOUR_MANAGEMENT_HOST
```

然后自己电脑浏览器打开 `http://127.0.0.1:5601`。不要用监听所有地址代替正式网关。用 `elastic` 完成初始管理后，应按团队权限建立日常用户；安装器没有自动创建业务只读用户。`kibana_system` 是服务账号，不用于人员登录。

### 创建日志数据视图

首次安装不会自动创建 Kibana Data View。至少有一条日志写入后：

1. 打开 Discover，选择创建 Data View；也可从 Stack Management → Data Views 创建。
2. 名称填 `Kubernetes Logs`，索引匹配填 `logs-k8s-*`。
3. 时间字段选择 `@timestamp` 并保存。
4. 回到 Discover，选择该视图，时间先选最近 15 分钟或最近 1 小时，刷新。

看不到索引时先按后文生成测试日志。不同版本布局可能有差别，可用全局搜索找到 Discover / Data Views。[Discover 官方说明](https://www.elastic.co/docs/explore-analyze/discover/discover-get-started)。

### 常用日志查询

在 Discover 的 **KQL** 模式分别输入以下查询（不是 Shell 命令）：

```text
kubernetes.namespace_name : "logging"
kubernetes.namespace_name : "aict" and kubernetes.container_name : "iam"
kubernetes.pod_name : "logging-smoke"
log : "ERROR" or log : "Exception"
message : "archinfra-logging-smoke"
```

推荐显示 `@timestamp`、`kubernetes.namespace_name`、`kubernetes.pod_name`、`kubernetes.container_name`、`log`，JSON 日志存在时再添加 `message`、`level`。

当前实际默认字段是 `kubernetes.namespace_name` / `kubernetes.pod_name`，**没有自动转成 ECS 的 `kubernetes.namespace` / `kubernetes.pod.name`**。JSON 内容尝试合并，原始 `log` 保留；只查询应用实际输出的字段。参见 [Fluent Bit Kubernetes filter](https://docs.fluentbit.io/manual/data-pipeline/filters/kubernetes)。

## 部署验收：确认日志真的写进来了

### 1. 检查运行资源和 ES 健康

```bash
helm -n logging status elasticsearch
kubectl -n logging get sts,deploy,ds,pods,pvc,svc
kubectl -n logging get events --sort-by=.metadata.creationTimestamp
```

ES 应为 `1/1` 或 `3/3`，Kibana/Exporter 为 `1/1`，PVC 为 Bound，Fluent Bit Ready 数等于 Desired 数。再核对业务所在节点是否都有 Fluent Bit；不同架构或存在不被容忍污点的节点可能不覆盖。

当前 ES 探针检查 TCP 端口，Pod Ready 不等于集群/索引健康。在 Kibana Dev Tools → Console 执行：

```http
GET /_cluster/health
GET /_cat/nodes?v
GET /_cat/indices/logs-k8s-*?v
GET /_ilm/policy/archinfra-logs-retain
GET /logs-k8s-*/_ilm/explain
```

核对节点数、集群健康及分片状态。yellow 表示存在未分配副本，red 表示有主分片不可用，均需排查。没有日志时索引查询可能为空或不存在。

### 2. 创建测试日志 Pod

复用包内 curl 镜像的 shell，不额外下载 busybox。先改实际 Registry；arm64 环境把镜像后缀和 nodeSelector 都改成 arm64：

```bash
kubectl -n logging run logging-smoke \
  --image=sealos.hub:5000/kube4/curl:8.16.0-amd64 \
  --image-pull-policy=IfNotPresent \
  --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}' \
  --command -- sh -c 'sleep 15; i=0; while [ "$i" -lt 60 ]; do echo "{\"message\":\"archinfra-logging-smoke\",\"level\":\"INFO\"}"; i=$((i+1)); sleep 2; done'

kubectl -n logging get pod logging-smoke -o wide
kubectl -n logging logs -f logging-smoke
```

确认 Pod 位于已运行 Fluent Bit 的节点。等待持续输出后，在 Discover 搜索 `kubernetes.pod_name : "logging-smoke"` 并展开文档，或在 Dev Tools 查询：

```http
GET /logs-k8s-*/_search
{
  "size": 10,
  "sort": [{"@timestamp": "desc"}],
  "query": {"match_phrase": {"log": "archinfra-logging-smoke"}}
}
```

验收后仅清理测试 Pod；再次测试前也先清理同名 Pod：

```bash
kubectl -n logging delete pod logging-smoke --ignore-not-found
```

只有在容器输出和 ES/Kibana 中查到同一标记，才验证了该节点的完整链路；仍不能代替其他节点和 HA 故障测试。

### 3. 可选：命令行查询 ES

管理机需另有 curl。终端 A 保持转发：

```bash
kubectl -n logging port-forward svc/elasticsearch-es 9200:9200
```

终端 B 导出公开 CA，用 curl 交互输入前文读取的 `elastic` 密码：

```bash
kubectl -n logging get secret elasticsearch-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > es-ca.crt
curl --cacert es-ca.crt --user elastic 'https://localhost:9200/_cluster/health?pretty'
```

证书包含 `localhost`，不包含 `127.0.0.1` 的 IP SAN，所以此处使用 `https://localhost`，无需 `-k`。不要把密码拼入 URL 或命令参数。

## 业务日志怎么接入

- 业务日志写到容器 stdout/stderr，节点 Fluent Bit 即可统一采集。建议输出单行 JSON，保持各字段类型稳定。
- MySQL 慢查询等如果只写在容器内部文件，**不会被当前配置自动采集**。需要改为输出到 stdout/stderr，或另行配置文件采集路径。
- 当前只采集 `/var/log/containers/*.log`，没有配置 journald、任意主机文件、Windows 事件日志。`docker, cri` 多行配置不代表已经处理所有 Java 业务堆栈。
- `Read_from_Head Off`：首次发现文件从尾部读取，不保证补采历史；已有 tail 数据库会记录读取位置。
- Kubernetes Labels/Annotations 默认关闭，没有自动脱敏或统一 ECS 转换。
- 当前为 `logs-k8s-*` 日索引 + ILM 删除策略，不是 Data Streams；删除异步执行，不是每条日志恰好第 14 天删除。
- 缓冲目录是 `/var/lib/archinfra/fluent-bit`，5G 为输出队列逻辑上限，不是整个节点磁盘的硬限额，缓冲耗尽仍可能丢日志。
- 不要在同一集群重复安装多套默认 Fluent Bit：可能重复采集，而且当前共用上述节点目录。仅另建 ES 后端时可用 `--disable-fluent-bit` 并另行设计路由。

## 监控怎么接入

`--enable-monitoring` 默认开启，但不会安装 Prometheus/Grafana：

| 对象 | 作用 |
| --- | --- |
| `elasticsearch-exporter:9114/metrics` | ES 指标 |
| `elasticsearch-fluent-bit-metrics:2020/api/v1/metrics/prometheus` | Fluent Bit 错误、重试等指标 |
| ServiceMonitor / PrometheusRule | 仅在已有对应 CRD 时创建 |
| `elasticsearch-grafana-dashboard` ConfigMap | 看板 JSON，标签 `grafana_dashboard=1`，文件夹注解 `grafana_folder=Middleware/Elasticsearch` |

Prometheus 的命名空间和标签选择器必须选中 `logging` 中的监控资源（标签 `monitoring.archinfra.io/stack=default`）。存在 CRD 不代表目标已经被选中。Grafana sidecar 需要发现该 ConfigMap，默认数据源应指向正确的 Prometheus。

```bash
kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
kubectl -n logging get servicemonitor,prometheusrule
kubectl -n logging port-forward svc/elasticsearch-exporter 9114:9114
```

另一终端用 `curl -fsS http://127.0.0.1:9114/metrics` 查看指标，再检查 Prometheus Targets。先装日志平台、后装监控 CRD 时，需重跑原完整安装命令，让 Helm 补建先前跳过的资源。

## 常见问题和排错

先使用只读命令保留现场：

```bash
helm -n logging status elasticsearch
helm -n logging history elasticsearch
kubectl -n logging get pods,pvc,jobs -o wide
kubectl -n logging get events --sort-by=.metadata.creationTimestamp
kubectl -n logging logs elasticsearch-es-0 --tail=100
kubectl -n logging logs deploy/elasticsearch-kibana --tail=100
kubectl -n logging logs ds/elasticsearch-fluent-bit --tail=100
kubectl -n logging logs deploy/elasticsearch-exporter --tail=100
```

DaemonSet 日志命令只选择一个 Pod。排查业务节点时，先通过 `get pods -o wide` 找到该节点的 Fluent Bit Pod 再读取其日志。

| 现象 | 检查方向 |
| --- | --- |
| `Missing embedded payload` | 使用了源码脚本；改用实际构建的完整 `.run` |
| `StorageClass not found` / PVC Pending | 核对类名、CSI、容量、卷拓扑；WaitForFirstConsumer 可能等待 Pod 调度后才绑定 |
| HA Pod Pending | 同架构节点数、可调度状态、污点、资源、反亲和与卷拓扑 |
| Docker push denied / TLS 错误 | 管理机仓库登录、路径及 CA/HTTP 信任 |
| `ImagePullBackOff` | Pod events、节点 DNS/网络、拉取认证/CA，镜像标签的架构后缀 |
| `exec format error` | 包、实际镜像平台、节点架构是否一致 |
| bootstrap 失败 | `kubectl -n logging logs job/elasticsearch-bootstrap --tail=100`；检查 ES、DNS、TLS、已有凭据。成功后 Job 已删除属于正常 |
| Kibana 尚未就绪 | bootstrap、Kibana 日志、ES 健康、系统账号认证和 CA |
| Fluent Bit unknown property | 使用 v0.2.1，确保 `storage.total_limit_size` 在 OUTPUT 段 |
| Pod 有日志但 Discover 没有 | 节点是否有采集器、时间范围、索引/字段、Fluent Bit 的 401/403、400 mapping 或重试错误 |
| 磁盘水位导致写入受阻 | 先处理容量、ILM 与分片，再处理写入保护，不要只关闭保护 |
| Secret 缺字段 / 401 | 核对 Secret 与 ES 实际凭据；不要删除 Secret 随机生成新密码 |
| topology/storage change 被拒绝 | 传回原 mode、StorageClass、storage-size；扩容/迁移走独立流程 |

第一阶段失败留下 Helm release 时，不要无限重跑：已有 release 会直接进入第二阶段，应先恢复 ES 和基础设施。排错共享日志/Helm 内容前先检查是否包含密码或其他敏感信息。

## 重跑、升级和卸载后的数据

保存各环境的完整安装命令。重跑时显式传回原 namespace、name、mode、profile、StorageClass、size、registry 和组件开关，安装器不会自动恢复你上次省略的非默认参数。

再次 `install` 会复用账号和 TLS 并协调 Helm 资源，可用于修复后重试、调整保留期/组件开关。例如只改保留期时，在原完整命令上修改 `--retention-days`；缩短保留期可能使已有受管理索引更早删除。

这不是任意 ES 跨版本升级工具。升级前必须评估兼容性、备份和恢复；当前普通安装不支持修改节点数、StorageClass 或 PVC 大小。

卸载后还会保留 namespace 和节点缓冲目录。可检查：

```bash
kubectl -n logging get pvc
kubectl -n logging get secret elasticsearch-auth elasticsearch-tls
```

要复用原数据，应保留同一 namespace/release、对应凭据和 TLS，使用兼容版本及原存储/拓扑；卸载重装后的恢复仍需现场验收。不要用删除命名空间代替普通卸载，PVC 保留也不等于备份。

## 现阶段安全边界与后续验证

- ES HTTP 和节点 Transport 都开启 TLS；Helm 初装创建 CA，后续升级复用同一份 Secret；证书有效期 3650 天，后续需要制定轮换策略。
- Kibana 的 HTTP Service 是集群内端口 5601；对外访问应通过受控 Ingress/HTTPS 或 `kubectl port-forward`。
- Fluent Bit 从 `/var/log/containers` 统一采集，使用文件系统缓冲；达到缓冲上限仍可能丢日志，需结合告警和磁盘规划。
- 在高吞吐部署时需评估 ES ILM、索引/副本、每日写入量、堆使用率、存储水位和 K8s 真实故障恢复。
- `node.store.allow_mmap=false` 避免强制宿主机设置 vm.max_map_count，但高负载生产集群建议进一步优化。
- 自维护 Helm Chart 的首次安装和 CI 静态/模拟测试不等于真实三节点 HA、断网恢复、滚动升级以及跨节点容灾 E2E。
- 尚未实现 Snapshot/Restore 自动编排；**PVC 保留不是备份**。
- Elastic 软件许可及客户二次分发权利需独立审查。

## 代码结构

```text
charts/elasticsearch/
  Chart.yaml
  values.yaml
  templates/      # TLS, StatefulSet, Kibana, Fluent Bit, exporter, ILM bootstrap
scripts/install/modules/
  00-header.sh    # CLI / 默认值
  10-actions.sh   # status / uninstall / preflight
  20-install.sh   # 镜像离线准备 + 双阶段 Helm install
scripts/assemble-install.sh
images/image.json
build.sh
tests/validate.sh
.github/workflows/build.yml
.github/workflows/validate.yml
```

更多采集和保留说明见 `docs/LOGGING.md`。版本锁和来源见 `UPSTREAM.yaml`。

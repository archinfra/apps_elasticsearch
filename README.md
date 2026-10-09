# Archinfra Elasticsearch Logging Stack

**v0.2.0 — 自维护 Helm Chart + 离线单文件 `.run`，完全不使用 ECK Operator。**

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

## 构建和产物

构建机需要：bash、Docker、Python 3、tar、sha256sum。GitHub Actions 分别构建两个架构，真正下载和打包官方容器镜像。

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
# 或 build.sh --arch all
```

产物：

```text
dist/elasticsearch-installer-v0.2.0-amd64.run
dist/elasticsearch-installer-v0.2.0-amd64.run.sha256
dist/elasticsearch-installer-v0.2.0-arm64.run
dist/elasticsearch-installer-v0.2.0-arm64.run.sha256
```

每个 `.run` 内包含 Helm Chart、对应 CPU 架构的五个镜像 tar、离线 image-index.tsv 和安装逻辑。镜像目标 tag 带 `-amd64` 或 `-arm64`；工作负载的 `nodeSelector` 也限制架构。**当前不创建混合架构 multi-platform manifest**，混合架构 K8s 集群只在与安装包同架构的节点调度本套工作负载。

## 安装

客户现场要求：helm、kubectl、bash、tar、od、base64；导入镜像时额外需要 Docker。helm 必须具备 StatefulSet、Secret、Namespace、RBAC 管理权限。

检查当前集群及 StorageClass：

```bash
kubectl config current-context
kubectl get nodes -L kubernetes.io/arch
kubectl get storageclass
```

**单节点开发环境：**

```bash
./elasticsearch-installer-v0.2.0-amd64.run install \
  --namespace logging \
  --mode single \
  --resource-profile lite \
  --storage-class ceph-rbd \
  -y
```

**三节点日志平台：**

```bash
./elasticsearch-installer-v0.2.0-amd64.run install \
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

### 为什么安装分两阶段

安装器先使用 Helm 创建 ES StatefulSet 和 TLS Secret，关闭其他组件，等待 ES Ready。然后通过 Helm pre-upgrade Job 调用 Elasticsearch API，创建：

- `kibana_system` 密码；
- `archinfra_log_writer` 仅对 `logs-k8s-*` 的写入权限；
- `archinfra_metrics` 只读监控权限；
- `archinfra-logs-retain` ILM 策略及日志 Index Template。

第二阶段升级 Helm release 启用 Kibana、Fluent Bit、Exporter。这样首次安装时 Kibana 不会因为缺少系统用户密码而阻塞 ES 启动。

### 资源规格（每个 ES Pod）

| 档位 | Request CPU / Memory | Limit CPU / Memory | 默认 PVC | JVM Heap |
| --- | --- | --- | --- | --- |
| lite | 500m / 2Gi | 1C / 4Gi | 30Gi | 2g |
| standard | 1C / 4Gi | 2C / 8Gi | 100Gi | 4g |
| large | 2C / 8Gi | 4C / 16Gi | 300Gi | 8g |

`--mode single` 为一节点非 HA；`--mode ha` 为三节点混合角色，严格跨节点反亲和。这些是初始资源规格，不等于已经验证的容量承诺。

## 日常管理

```bash
./elasticsearch-installer-v0.2.0-amd64.run status -n logging
kubectl -n logging get sts,deploy,ds,pods,pvc
kubectl -n logging port-forward svc/elasticsearch-kibana 5601:5601
kubectl -n logging get secret elasticsearch-auth -o jsonpath='{.data.elastic-password}' | base64 -d
```

浏览器访问 `http://127.0.0.1:5601`，用户 `elastic`，密码从 Secret 读取。Kibana 端口转发经 SSH/堡垒机保护，不建议随意直接发布公网入口。

卸载：

```bash
./elasticsearch-installer-v0.2.0-amd64.run uninstall --namespace logging -y
```

默认保留 ES PVC、`<release>-auth` 和 `<release>-tls`。不支持自动毁灭数据的卸载参数。PVC 扩容、迁移 StorageClass、节点数量变更需要专门的变更/备份流程，不允许普通安装覆盖。

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

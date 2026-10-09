# Archinfra Elasticsearch 日志体系 — 交付契约 v0.2.0

## 拓扑

Kubernetes CRI 容器日志 -> Fluent Bit DaemonSet -> HTTPS / Elasticsearch（StatefulSet）-> Kibana（Deployment）

Elasticsearch 和 Kibana 由项目自维护 Helm Chart 部署，没有 Operator/CRD，也不依赖 Logstash。MySQL、Redis、MongoDB、Nacos 默认输出 stdout/stderr 后统一采集；不建议给每个中间件再加 Fluent Bit Sidecar。

## 安全与访问

- TLS：Helm 初次生成集群 CA、服务证书，保存为 <release>-tls Secret；Transport mTLS/HTTP TLS 使用同一 CA 签发的证书。
- 管理密码：<release>-auth Secret 中的 elastic-password，首次随机生成，再次安装原样复用。
- Kibana：kibana_system 专用密码，前置 bootstrap Job 经安全 API 初始化。
- Fluent Bit：archinfra_log_writer 专用账号，限定 logs-k8s-* 写入权限，禁止使用 elastic 超级管理员常驻采集进程。
- Exporter：archinfra_metrics 专用监控账号，只有 cluster monitor 和 index monitor 权限。
- 暴露面：所有服务默认 ClusterIP。Kibana 5601 仅经本地 port-forward 或企业受控 HTTPS 网关访问。
- Registry：构建产物不携带 Registry 明文密码。客户现场可用 password-file，或配置镜像提前入库。

## 数据保留与成本

- Fluent Bit 文件系统缓冲使用 /var/lib/archinfra/fluent-bit hostPath；每节点逻辑上限默认为 5G，断链时可能积压或丢失，必须监控。
- 第一期使用 logs-k8s-* 日索引，内置 ILM 14d 自动删除策略（--retention-days 参数化）。
- 默认单节点索引副本数为 0；HA 三节点为 1，主分片数为 1。集群流量增长后需评估 shard 数量、索引合并、查询压力和磁盘使用率。
- 日志字段标准建议参考 ECS：@timestamp、log.level、service.name、kubernetes.namespace、kubernetes.pod.name、trace.id。
- 脱敏、审计日志保留期、跨集群采集、多租户权限和补采机制应根据现场合规要求完成验收，不应把默认 14d 视为统一审计合规期限。
- 数据快照未实现；生产必须在上线前补 ES Snapshot 仓库、恢复演练及回滚方案。

## 监控和看板

- Elasticsearch exporter metrics Service：<release>-exporter:9114，默认采集集群/分片/索引指标。
- Fluent Bit 自带 HTTP metrics：<release>-fluent-bit-metrics:2020，Prometheus 路径 /api/v1/metrics/prometheus。
- 存在 ServiceMonitor/PrometheusRule CRD 时 Chart 自动创建关联对象，标签 monitoring.archinfra.io/stack=default。
- Grafana 配置发现标签 grafana_dashboard=1、grafana_folder=Middleware/Elasticsearch。
- 基础告警包含 ExporterDown、ClusterRed、UnassignedShards；建议在正式环境另加 JVM Heap、磁盘 80/90%、日志输出重试和磁盘 Buffer 容量告警。

## 已验证与未验证

已由 CI 校验：shell 语法、Helm 单节点/HA 渲染、两阶段安装的 mock 流程、离线 BOM 结构。
离线构建需要独立验证 amd64 和 arm64 的五个镜像拉取、docker save、.run checksum 和 artifact 上传。
尚缺：真实 Kubernetes 三节点 HA E2E、Kibana 系统账号/Fluent Bit 真实鉴权写入、TLS 证书续期/轮换、存储失效恢复、快照和跨架构混合集群。

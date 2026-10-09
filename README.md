# archinfra/apps_elasticsearch

Kubernetes Elasticsearch / Kibana / Fluent Bit 私有化离线交付仓库。遵循 Archinfra 的 .run 单文件安装器、amd64/arm64 架构、镜像离线打包、统一 CLI 参数与监控治理路线。

## 当前基线

| 组件 | 版本 |
| --- | --- |
| Installer | 0.1.0 |
| Elasticsearch | 9.5.5 |
| Kibana | 9.5.5 |
| Elastic Cloud on Kubernetes (ECK) | 3.5.0 |
| Fluent Bit | 5.1.3 |

仓库采用模块化脚本：scripts/install/modules/*.sh 是安装器真源，scripts/assemble-install.sh 用于生成 install.sh；build.sh 同时完成安装器组装、ECK 官方 CRD/Operator Manifest 打包、镜像离线 tar 封装和 SHA256 校验。

## 构建

构建机需：bash、docker、curl、python3、tar、sha256sum。客户运行最终 .run 无需 Python、jq、curl、Helm。

    bash tests/validate.sh
    bash build.sh --arch amd64
    bash build.sh --arch arm64

产物：

    dist/elasticsearch-installer-v0.1.0-amd64.run
    dist/elasticsearch-installer-v0.1.0-amd64.run.sha256
    dist/elasticsearch-installer-v0.1.0-arm64.run
    dist/elasticsearch-installer-v0.1.0-arm64.run.sha256

GitHub Actions 的 Validate 在 push、PR 时运行模拟安装测试；Build Offline Run 在版本 tag 或手动 workflow_dispatch 时下载上游镜像并构建离线包。amd64 与 arm64 分别运行。

## 部署

所有安装均须显式指定现场可用 StorageClass，不默认选 NFS。请先检查 Kubernetes context。

    kubectl config current-context
    kubectl get storageclass
    ./elasticsearch-installer-v0.1.0-amd64.run help

单节点实验环境（非 HA）：

    ./elasticsearch-installer-v0.1.0-amd64.run install \
      --namespace logging \
      --mode single \
      --resource-profile lite \
      --storage-class ceph-rbd \
      -y

三节点高可用基础形态（需至少 3 台可调度 Kubernetes Worker）：

    ./elasticsearch-installer-v0.1.0-amd64.run install \
      --namespace logging \
      --mode ha \
      --resource-profile standard \
      --storage-class ceph-rbd \
      --storage-size 100Gi \
      -y

ceph-rbd 只是示例，不是仓库默认值。首次安装会在没有 ECK CRD 时提交内置的 ECK 3.5.0 Manifest；如已有 ECK，则复用现有 Operator。所有 ES 和 Kibana 服务均默认 ClusterIP，ECK 管理 HTTPS 与安全凭据。安装器不会卸载共享 ECK CRD/Operator。

默认目标镜像仓库为 sealos.hub:5000/kube4。已经预先上传镜像时，可传 --skip-image-prepare。需要 Registry 登录时，使用 --registry-user 和 --registry-password-file，避免把密码写在命令行里。

## Kibana 和状态

    ./elasticsearch-installer-v0.1.0-amd64.run status -n logging
    kubectl -n logging get elasticsearch,kibana,pods,pvc
    kubectl -n logging port-forward svc/elasticsearch-kb-http 5601:5601
    kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d

## 可选 Fluent Bit 日志采集

本仓库内置 Fluent Bit DaemonSet 模板，避免把日志采集硬塞进每个 MySQL、Redis、Nacos Pod。采集器默认关闭；开启时必须先为 ES 创建权限受限的日志写入用户，将用户名密码写入 logging Namespace 下的 Kubernetes Secret（键：username / password）。

    ./elasticsearch-installer-v0.1.0-amd64.run install \
      --namespace logging \
      --storage-class ceph-rbd \
      --enable-collector \
      --collector-secret elastic-log-writer \
      -y

采集器从 /var/log/containers 读取 CRI 日志，添加 Kubernetes 元数据，使用 ECK CA 验证 TLS，按 logs-k8s-* 写入索引。它不会使用 elastic 超管账户。**上线前需补齐索引生命周期/保留策略、敏感信息脱敏和采集链路压力测试**。详见 docs/LOGGING.md。

## 资源规格

| profile | 单 ES 节点 CPU request/limit | 内存 request/limit | 默认 PVC |
| --- | --- | --- | --- |
| lite | 500m / 1 | 2Gi / 4Gi | 30Gi |
| standard | 1 / 2 | 4Gi / 8Gi | 100Gi |
| large | 2 / 4 | 8Gi / 16Gi | 300Gi |

HA=3 个混合角色节点，严格跨主机反亲和；lite 不允许 HA。为避免安装器要求节点特权 sysctl，当前 node.store.allow_mmap=false；生产性能优化需按 ECK 官方要求配置宿主机 vm.max_map_count。

## 卸载与安全

    ./elasticsearch-installer-v0.1.0-amd64.run uninstall -n logging -y

卸载只删除本仓库对应的 Elasticsearch/Kibana 和 Fluent Bit 资源，不删除共享 ECK Operator / CRD。Elasticsearch 使用 volumeClaimDeletePolicy: DeleteOnScaledownOnly，删除 ES CR 后保留 PVC。**保留 PVC 不是备份**，Snapshot 与恢复演练会在后续版本补齐。

Elasticsearch / Kibana / ECK 属于 Elastic 许可体系，不应视作纯 Apache-2.0 发行包，正式商业再分发需复核授权。镜像目前按固定版本锁定；digest 签名与 SBOM 是后续供应链增强内容。

## 目前的交付边界

0.1.0 是第一阶段可执行代码基线，GitHub Actions 的静态/模拟测试不等于真实 K8s E2E。正式上线前还需要：双架构真实安装测试、异构集群的多平台镜像 manifest、ES 指标监控/告警、索引生命周期、快照恢复和滚动升级压力测试。

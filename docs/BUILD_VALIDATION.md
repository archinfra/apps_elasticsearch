# v0.2.1 构建与排错记录

## Root Cause Analysis

**Error**: Fluent Bit Helm 模板把 `storage.total_limit_size` 放在 `[INPUT]` 段。

**Expected**: 对 Elasticsearch 输出的磁盘缓冲队列设置 5G 上限，Fluent Bit 能正常加载配置。

**Cause**: 该参数属于输出插件。原有 CI 只渲染 YAML、模拟 Helm 和检查整个安装包 SHA256，没有调用 Fluent Bit 验证实际配置，因此不能发现插件配置错误。

**Fix**: 将上限放在 `[OUTPUT]` 段，保留 INPUT 的 `storage.type filesystem` 和 SERVICE 的 `storage.path`。

**Prevention**: 双架构构建任务使用各自原生镜像执行配置检查，并确认旧错误配置会被拒绝。随后检查 `.run` 内五个 Docker 归档的 Linux/CPU 平台、标签、镜像层、版本和导入索引，最后验证 SHA256 并上传产物。

参考：[Fluent Bit buffering and storage](https://docs.fluentbit.io/manual/administration/buffering-and-storage)。

## 任务和验收范围

1. Validate：Bash 语法、Helm lint、single/HA 渲染、CLI 校验、模拟两阶段安装与卸载、ShellCheck。
2. Build Offline Run / amd64：下载五个镜像、核验平台、生成 `.run`、真实 Fluent Bit 配置检查、成品归档检查、SHA256、Artifact 上传。
3. Build Offline Run / arm64：在原生 arm64 Runner 执行同样的步骤。
4. 真实 Kubernetes 验收仍需单独执行：ES 集群健康、Kibana 登录、Fluent Bit 日志可检索、断链积压恢复、PVC 保留、升级及快照恢复。

构建成功和镜像配置检查不代表第 4 项完成。当前不增加 Operator，也不在构建期间连接客户集群。

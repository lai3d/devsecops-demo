# devsecops-demo

[English](README.md) | **中文**

一个小型 Go 服务，外面包着一条安全的软件供应链：每次变更合并前都要扫描，每次发布都要签名并附带 SBOM，集群只接受由本仓库 release workflow 签名的镜像。每次发布都会起一个临时集群，端到端验证上述所有环节。

```
pull request ─▶ gitleaks ─▶ semgrep ─▶ zizmor ─▶ go test + govulncheck ─▶ trivy fs ─▶ trivy image
                （密钥）    （SAST）   （workflow   （单元测试、可达的      （依赖、IaC、  （构建出的
                                        审计）       Go 漏洞）              密钥）         镜像）

合并到 main ─▶ 同样的关卡 ─▶ 按 digest 推送到 GHCR ─▶ cosign 签名（keyless、OIDC）
            ─▶ Syft SBOM ─▶ cosign attest ─▶ cosign verify ─▶ trivy sbom
            ─▶ kind + Cilium ─▶ Kyverno 准入测试 ─▶ Argo CD 部署 ─▶ Tetragon 检测
```

## 每道关卡证明什么

| 阶段 | 工具 | 什么情况下构建失败 |
|---|---|---|
| 密钥 | gitleaks（完整历史） | 任意一次提交中出现凭据 |
| SAST | Semgrep：`p/golang`、`p/dockerfile`、`p/github-actions`、`p/kubernetes` | 规则命中 |
| Workflow 审计 | zizmor | workflow 存在中危及以上问题：模板注入、权限过宽、凭据残留 |
| SCA | govulncheck | 代码**实际调用**到已知有漏洞的 Go 函数（包括标准库） |
| SCA + IaC | Trivy `fs` | 存在可修复的高危/严重 CVE，或 Dockerfile、Helm chart、Kubernetes YAML、Terraform 有错误配置 |
| 镜像 | Trivy `image` | 构建出的镜像存在可修复的高危/严重 CVE |
| 签名 | cosign keyless | —— 用 workflow 的 GitHub OIDC 身份签名，没有需要保管或可能泄露的密钥 |
| SBOM | Syft → cosign attest | —— CycloneDX SBOM 以签名 attestation 的形式附加到镜像上 |
| 验证 | cosign verify / verify-attestation | 签名或 attestation 不是由 `main` 上的 `release.yml` 产生 |
| 准入 | Kyverno `ImageValidatingPolicy` + `ValidatingPolicy` | 见下方准入测试 |
| 部署 | Argo CD | 应用在已签名 digest 上未达到 `Synced/Healthy` |
| 运行时 | Tetragon `TracingPolicy` | Pod 内读取 `/etc/shadow` **没有**被上报 |

### 准入测试（`scripts/e2e-admission.sh`）

全部针对 `demo` 命名空间运行。该命名空间强制 Pod Security `restricted`，并启用供应链策略。

| Pod 镜像 | 预期 |
|---|---|
| `docker.io/library/nginx:latest` | 拒绝：仓库不对，且没有用 digest |
| `ghcr.io/lai3d/devsecops-demo:sha-…`（已签名，但用的是 tag） | 拒绝：没有用 digest |
| `ghcr.io/lai3d/devsecops-demo@sha256:…`（未签名） | 拒绝：不是 release workflow 签的 |
| `ghcr.io/lai3d/devsecops-demo@sha256:…`（已签名） | 允许 |

## 仓库本身的加固

- 所有 action 都锁定到完整 commit SHA，所有容器镜像都按 digest 锁定；由 Dependabot 为 action、镜像、Go 模块和 Terraform provider 提出更新。
- 扫描器以锁定 digest 的容器运行，而不是通过第三方 action，减少信任链上的第三方 action。
- Workflow 默认 `permissions: {}`，每个 job 只申请所需权限；`id-token: write` 只出现在签名 job 上。
- `actions/checkout` 设置 `persist-credentials: false`。
- 任何地方都不存储云密钥。启用 AWS 访问时，使用仅限本仓库 `main` 分支的 OIDC 联合身份（`infra/aws-github-oidc`）。

## 运行时加固（Helm chart）

按 digest 部署 · 非 root UID 65532 · 只读根文件系统 · 去掉全部 capabilities · 禁止提权 · `RuntimeDefault` seccomp · 不挂载 service account token · 默认拒绝的 `NetworkPolicy`（只允许命名空间内访问 8080，无出站）· 无 shell 的 distroless 基础镜像。

## 目录结构

```
cmd/server/              Go 服务（net/http，仅标准库）
Dockerfile               多阶段构建，distroless，基础镜像锁定 digest
deploy/helm/             加固过的 chart
deploy/cluster/          kind 配置（Cilium CNI）和强制策略的命名空间
deploy/argocd/           Argo CD 仓库凭据 + Application 模板
policies/kyverno/        签名校验、digest 与仓库限制
policies/tetragon/       敏感文件访问检测
infra/aws-github-oidc/   Terraform：GitHub OIDC provider + 仅限 main 的角色
scripts/                 准入测试
docs/threat-model.md     STRIDE 威胁模型（英文）及对应控制措施
```

## 如何运行

- **Pull request** 触发 `ci.yml`。
- **合并到 `main`** 触发 `release.yml`：再跑一遍所有关卡，然后发布、签名、attest，并做端到端集群测试。
- **AWS 联合身份**（可选）：用管理员 profile 执行 `terraform -chdir=infra/aws-github-oidc apply`，把仓库变量 `AWS_ROLE_ARN` 设为输出的 `role_arn`，然后从 `main` 运行 `aws-oidc-check` workflow。
- **本地**：`go test ./...`；执行 `pre-commit install` 启用 gitleaks 钩子。

## 说明

- Keyless 签名会在公开的 Rekor 透明日志中写入一条记录，记录里有本仓库名、workflow 和 commit。仓库为私有时也一样。
- e2e job 会向同一个 package 推送一个刻意未签名、tag 为 `e2e-unsigned` 的镜像，让签名策略有东西可以拒绝。
- 私有期间未启用：OpenSSF Scorecard（workflow 会跳过私有仓库）、GitHub artifact attestations、代码扫描（SARIF）上传。这几项都需要公开仓库或付费计划。

## 威胁模型

见 [docs/threat-model.md](docs/threat-model.md)（英文）。

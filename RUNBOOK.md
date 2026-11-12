# Smoke Test Runbook — 用个人账号验证发布链路

目的：在碰公司账号之前，用**你自己的 GitHub 仓库 + 你自己的 npm 账号**把整条链路跑通，确认没有隐藏问题。

- 包名：`qiaojin923-npm-cicd-smoke-test`（已验证可用）
- npm 账号：`qiaojin`（注意与 GitHub 的 `qiaojin923` 不同名）
- 仓库：https://github.com/qiaojin923/cicd-smoke-test （public，已创建）
- workflow：与生产**完全相同的文件**，零改动
- 唯一替代：CDN 换成 `raw.githubusercontent.com`（同为匿名可读的 HTTPS 静态地址）

---

## 已实测的两个结论（直接影响生产方案）

### 结论一：新包无法提前配置 trusted publisher（C1 已实测）

对尚不存在的包执行 `npm trust github` 会直接 403：

```
npm error 403 403 Forbidden - POST https://registry.npmjs.org/-/package/<pkg>/trust
```

原因：`/-/package/<name>/trust` 是**包级**接口，包不存在就没有所有者，也就没有权限。所以第一次必须先用传统方式把包发出来。

**生产影响**：正式包首发不能走「配 trust → 打 tag → CI 发布」这条路，必须是「人工 token 发首版 → 配 trust → 之后才全自动」。

### 结论二：首发发布必须人工提供 OTP，无法脚本化

```
npm error 403 PUT https://registry.npmjs.org/<pkg>
  - Two-factor authentication or granular access token with bypass 2fa enabled is required to publish packages.
```

非交互环境（脚本、CI、agent）无法完成这一步。**生产影响**：首发是一次必须有人在场的人工操作，之后才进入全自动；同时这条也解释了为什么值得尽早切到 OIDC——只有 OIDC 发布不需要 OTP。

---

## 前置

```bash
gh auth status || gh auth login
cd cicd-smoke-test
export GH_USER=qiaojin923
```

---

## 步骤

### 1. 登录 npm（如果还没登录）

```bash
npm login --registry https://registry.npmjs.org/
npm whoami  --registry https://registry.npmjs.org/     # 应为 qiaojin
```

### 2. 引导首版发布（人工，会提示输入 OTP）

**这一步必须在终端交互执行**，准备好手机上的 6 位验证码。

```bash
npm publish ./artifacts/qiaojin923-npm-cicd-smoke-test-0.1.0.tgz \
  --access public --registry https://registry.npmjs.org/
```

> 注意 `./` 前缀。不加会被 npm 当成 GitHub 简写 `artifacts/...` 去 SSH clone 而报错。

验证发布结果，并顺带核对**字节一致性**（这是我们此前只在理论上论证过的一点）：

```bash
npm view qiaojin923-npm-cicd-smoke-test version --registry https://registry.npmjs.org/
npm view qiaojin923-npm-cicd-smoke-test dist.integrity --registry https://registry.npmjs.org/
# 本地对同一份 tgz 算 sha512，应该与上面的 integrity 完全一致
node -e '
const crypto=require("crypto"), fs=require("fs");
const b=fs.readFileSync("./artifacts/qiaojin923-npm-cicd-smoke-test-0.1.0.tgz");
console.log("sha512-"+crypto.createHash("sha512").update(b).digest("base64"))
'
```

### 3. 配置 trusted publisher（现在包已存在，应该能成功）

```bash
npm trust github qiaojin923-npm-cicd-smoke-test \
  --file publish.yml \
  --repository qiaojin923/cicd-smoke-test \
  --allow-publish -y \
  --registry https://registry.npmjs.org/

npm trust list qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

### 4. 打 tag 触发 CI 发布（版本必须是新的）

因为 `0.1.0` 已被首发占用，CI 测试要用 `0.1.1`：

```bash
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.1 DIST_TAG=latest \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.1"
git push
git tag v0.1.1 && git push origin v0.1.1
```

打开 Actions 看日志，重点确认：

- `Read release manifest` 输出 `distTag=latest`
- `Verify sha256` 的 expected / actual 一致
- `Publish to npm` 输出 `with tag latest and public access`，**不能**出现 `ENEEDAUTH`

**这一步如果成功，就证明 OIDC 链路打通了**——日志里不会有任何 OTP 提示，这是它和首发最大的区别。

### 5. 验证结果

```bash
npm dist-tag ls qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
npm view qiaojin923-npm-cicd-smoke-test dist-tags --json --registry https://registry.npmjs.org/
```

页面：https://www.npmjs.com/package/qiaojin923-npm-cicd-smoke-test
因为是**公开仓库**，这里应该能看到 **provenance 徽章**，点开能看到仓库 / commit / workflow。

### 6. 测 hotfix 通道

```bash
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.2-hotfix.1 DIST_TAG=hotfix \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.2-hotfix.1"
git push
git tag v0.1.2-hotfix.1 && git push origin v0.1.2-hotfix.1

npm dist-tag ls qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

预期：`latest` 仍是 `0.1.1`，`hotfix` 指向 `0.1.2-hotfix.1`。**验证「预发版不会顶掉 latest」。**

### 7. 测失败路径（验证护栏真的有效）

```bash
# (a) 版本号不一致：把 releases/0.1.1.json 的 version 改成 9.9.9
# (b) sha256 不符：把 releases/0.1.1.json 的 sha256 改任意一位
# (c) 预发布硬打 latest：打包阶段就会被拒
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.3-rc.1 DIST_TAG=latest \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh
```

改完 (a) 或 (b) 后重推 tag 触发：

```bash
git commit -am "test: negative case" && git push
git tag -f v0.1.1 && git push origin v0.1.1 --force
```

Actions 里应看到明确的 `::error::`，且失败发生在 Publish 之前。

---

## 已知坑

| # | 坑 | 处理 |
|---|---|---|
| 1 | `gh repo create --source=.` 要求目录已是 git 仓库 | 先 `git init` 再建仓库 |
| 2 | `npm publish artifacts/xxx.tgz` 被当成 GitHub 简写 | 加 `./` 前缀或写绝对路径 |
| 3 | 新包配 trust 必 403 | 先人工发布首版 |
| 4 | 发布需要 OTP，脚本/CI 无法代劳 | 首发人工执行，之后交给 OIDC |
| 5 | `pack.sh` 默认版本取自 `pkg/package.json` | 显式传 `VERSION=` |
| 6 | 整包 unpublish 后同名 24 小时内不能重发 | 用递增版本号 |

---

## 用完清理

```bash
npm unpublish qiaojin923-npm-cicd-smoke-test --force --registry https://registry.npmjs.org/
gh repo delete qiaojin923/cicd-smoke-test --yes
```

---

## 这个测试验证不到什么

| 未覆盖 | 原因 | 生产上怎么兜 |
|---|---|---|
| 真实 CDN（download.agora.io） | 无上传权限 | 用 raw.githubusercontent 替代，行为等价（匿名 HTTPS + sha256 校验） |
| 公司账号 agora.io 的 owner 权限与 2FA 归属 | 个人账号测不了 | 评审问题第 5 项要求明确 owner + backup |
| 352 KB / 6 文件的大包 | smoke test 只有 940 字节 | 生产的 `npm publish --dry-run` 已验证输出 6 个文件 |
| 私有仓库 → 无 provenance | 测试仓库是 public | 生产方案已按 private 设计，预期本来就没有徽章 |

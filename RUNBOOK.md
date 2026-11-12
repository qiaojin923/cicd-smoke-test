# Smoke Test Runbook — 用个人账号验证发布链路

目的：在碰公司账号之前，用**你自己的 GitHub 仓库 + 你自己的 npm 账号**把整条链路跑通。

- 包名：`qiaojin923-npm-cicd-smoke-test`
- npm 账号：`qiaojin`（与 GitHub 的 `qiaojin923` **不需要同名**，两者唯一的联系是 trusted publisher 里填的仓库地址）
- 仓库：https://github.com/qiaojin923/cicd-smoke-test （public，已创建）
- 两个 workflow：
  - `publish.yml` —— 正常发版，纯 OIDC，与生产**完全相同的文件**，零改动
  - `bootstrap-publish.yml` —— 一次性引导首版，用临时 token，用完即弃

---

## 为什么首次发布必须单独处理

**npm 不支持对尚不存在的包创建 trusted publisher。** 实测（unscoped 与 scoped 都试过）：

```
403 Forbidden - POST https://registry.npmjs.org/-/package/<pkg>/trust
```

npm CLI 的 `otplease` 只在收到 `EOTP`(401) 时才提示输入验证码，403 会被直接抛出，所以这**不是缺 OTP，而是没有该包的权限**——包不存在就没有所有者。PyPI 有 pending publisher 机制可以规避这一点，npm 没有。

因此顺序只能是：**先发一版让包存在 → 配 trusted publisher → 之后全部走 OIDC**。

为了不用手工在本地发布，这里把「首版」也放进 CI，只是那一次用临时 granular token，发完立刻销毁。

---

## 步骤

### 1. 创建临时 granular token

npmjs.com → 右上头像 → Access Tokens → Generate New Token → **Granular Access Token**：

- Token name：`smoke-test-bootstrap`
- Expiration：7 days
- Packages and scopes：**All packages**，权限 **Read and write**
- 勾选 **bypass 2FA**（发布必须）

拿到 `npm_xxx...` 之后存成仓库 secret：

```bash
cd /Users/admin/Documents/deepseek-harness/default-workspace/cicd-smoke-test
gh secret set NPM_TOKEN --body 'npm_你的token'
gh secret list
```

> 这个 token 只服务于首版发布，第 4 步会立即 revoke。

### 2. 在 CI 里发首版

```bash
gh workflow run bootstrap-publish.yml -f manifest=0.1.0.json
gh run watch
```

日志里应看到 `Verify sha256` 通过、`Publish with token` 成功。这一步验证的是「CI 能发布」，但**还不是 OIDC**。

发布后核对字节一致性（这是我们之前只论证未实测的点）：

```bash
npm view qiaojin923-npm-cicd-smoke-test version --registry https://registry.npmjs.org/
npm view qiaojin923-npm-cicd-smoke-test dist.integrity --registry https://registry.npmjs.org/
node -e 'const c=require("crypto"),f=require("fs");console.log("sha512-"+c.createHash("sha512").update(f.readFileSync("./artifacts/qiaojin923-npm-cicd-smoke-test-0.1.0.tgz")).digest("base64"))'
```

两行走出来的值必须完全一致。

### 3. 立即销毁临时 token

```bash
gh secret delete NPM_TOKEN
```

再去 npmjs.com → Access Tokens 把 `smoke-test-bootstrap` revoke 掉。**确认这一步做完再往下走。**

### 4. 配置 trusted publisher（本地执行，需要 OTP）

```bash
npm whoami --registry https://registry.npmjs.org/     # 应为 qiaojin

npm trust github qiaojin923-npm-cicd-smoke-test \
  --file publish.yml \
  --repository qiaojin923/cicd-smoke-test \
  --allow-publish -y \
  --registry https://registry.npmjs.org/

npm trust list qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

包现在已经存在，这一步应该能成功。

### 5. 用 OIDC 发布第二个版本（关键验证）

`0.1.0` 已被占用，用 `0.1.1`：

```bash
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.1 DIST_TAG=latest \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.1"
git push
git tag v0.1.1 && git push origin v0.1.1
```

**判断标准**：日志里 `Publish to npm` 输出 `with tag latest and public access`，且

- 没有 `ENEEDAUTH`
- 没有任何 OTP 提示
- 仓库里没有任何 npm token secret（第 3 步已删）

同时出现这三点，才说明 OIDC 真的生效了。

### 6. 验证结果

```bash
npm dist-tag ls qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

页面：https://www.npmjs.com/package/qiaojin923-npm-cicd-smoke-test
因为是**公开仓库**，应能看到 **provenance 徽章**（点开有仓库 / commit / workflow）。注意：`0.1.0` 是 token 发的，没有徽章；`0.1.1` 是 OIDC 发的，才有。**这个对比本身就是给评审看的好材料。**

### 7. 测 hotfix 通道

```bash
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.2-hotfix.1 DIST_TAG=hotfix \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.2-hotfix.1"
git push && git tag v0.1.2-hotfix.1 && git push origin v0.1.2-hotfix.1

npm dist-tag ls qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

预期：`latest` 仍是 `0.1.1`，`hotfix` 指向 `0.1.2-hotfix.1`。

### 8. 测失败路径

```bash
# (a) 版本号不一致：改 releases/0.1.1.json 的 version 为 9.9.9
# (b) sha256 不符：改 releases/0.1.1.json 的 sha256 任意一位
# (c) 预发布硬打 latest：打包阶段就会拒绝
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.3-rc.1 DIST_TAG=latest \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh

git commit -am "test: negative case" && git push
git tag -f v0.1.1 && git push origin v0.1.1 --force
```

应有明确的 `::error::`，且失败在 Publish 之前。

---

## 已知坑

| # | 坑 | 处理 |
|---|---|---|
| 1 | `gh repo create --source=.` 要求目录已是 git 仓库 | 先 `git init` |
| 2 | `npm publish artifacts/xxx.tgz` 被当成 GitHub 简写 | 加 `./` 前缀或用绝对路径 |
| 3 | 新包配 trust 必 403（scoped 也一样） | 先发首版让包存在 |
| 4 | 首版发布需要 2FA，脚本/CI 无法代劳 | 用带 bypass 2FA 的 granular token，用完立即 revoke |
| 5 | `pack.sh` 默认版本取自 `pkg/package.json` | 显式传 `VERSION=` |
| 6 | 整包 unpublish 后同名 24 小时内不能重发 | 用递增版本号 |

---

## 用完清理

```bash
npm unpublish qiaojin923-npm-cicd-smoke-test --force --registry https://registry.npmjs.org/
gh repo delete qiaojin923/cicd-smoke-test --yes
```

---

## 覆盖不到的部分

| 未覆盖 | 原因 | 生产怎么兜 |
|---|---|---|
| 真实 CDN | 无上传权限 | raw.githubusercontent 替代，行为等价 |
| agora.io 的 owner 权限与 2FA 归属 | 个人账号测不了 | 评审问题第 5 项 |
| 352 KB / 6 文件的大包 | 只有 940 字节 | 生产已用 dry-run 验证 6 个文件 |
| 私有仓库无 provenance | 测试仓库是 public | 生产按 private 设计，本来就没有 |

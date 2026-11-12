# Smoke Test Runbook — 用个人账号验证发布链路

目的：在碰公司账号之前，用**你自己的 GitHub 仓库 + 你自己的 npm 账号**把整条链路跑通。

- 包名：`qiaojin923-npm-cicd-smoke-test`
- npm 账号：`qiaojin`（与 GitHub 的 `qiaojin923` **不需要同名**；两者的唯一联系是 trusted publisher 里填的仓库地址）
- 仓库：https://github.com/qiaojin923/cicd-smoke-test （public，已创建）
- workflow：只有 `publish.yml` 一个，与生产**完全相同的文件**，零改动
- 原则：**仓库里不出现任何 npm token**，首版由人工在本机发布

---

## 为什么首版必须人工

**npm 不支持对尚不存在的包创建 trusted publisher。** 实测（unscoped 与 scoped 都试过）：

```
403 Forbidden - POST https://registry.npmjs.org/-/package/<pkg>/trust
```

npm CLI 的 `otplease` 只在收到 `EOTP`(401) 时才提示输验证码，403 会被直接抛出，所以这**不是缺 OTP，而是没有该包的权限**——包不存在就没有所有者。PyPI 有 pending publisher 可以规避，npm 没有。

另外，发布本身要求 2FA OTP，非交互环境无法完成。

因此顺序只能是：**本机人工发一版让包存在 → 配 trusted publisher → 之后全部走 OIDC**。首版这一次是全程唯一的人工发布。

---

## 步骤

### 1. 登录并发布首版（人工，会提示输入 OTP）

准备好手机上的 6 位验证码，在**你自己的终端**里执行：

```bash
cd /Users/admin/Documents/deepseek-harness/default-workspace/cicd-smoke-test

npm login --registry https://registry.npmjs.org/
npm whoami  --registry https://registry.npmjs.org/     # 应为 qiaojin

npm publish ./artifacts/qiaojin923-npm-cicd-smoke-test-0.1.0.tgz \
  --access public --registry https://registry.npmjs.org/
```

> 注意 `./` 前缀。不加会被 npm 当成 GitHub 简写 `artifacts/...` 去 SSH clone，报 `Permission denied (publickey)`。

### 2. 核对字节一致性

```bash
npm view qiaojin923-npm-cicd-smoke-test version --registry https://registry.npmjs.org/
npm view qiaojin923-npm-cicd-smoke-test dist.integrity --registry https://registry.npmjs.org/

node -e 'const c=require("crypto"),f=require("fs");console.log("sha512-"+c.createHash("sha512").update(f.readFileSync("./artifacts/qiaojin923-npm-cicd-smoke-test-0.1.0.tgz")).digest("base64"))'
```

两行必须完全一致。这是「发布 tgz = 发解压后的内容，且字节不变」的直接证据。

### 3. 配置 trusted publisher（包已存在，可成功）

```bash
npm trust github qiaojin923-npm-cicd-smoke-test \
  --file publish.yml \
  --repository qiaojin923/cicd-smoke-test \
  --allow-publish -y \
  --registry https://registry.npmjs.org/

npm trust list qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

### 4. 用 OIDC 发第二个版本（核心验证）

`0.1.0` 已被占用，用 `0.1.1`：

```bash
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.1 DIST_TAG=latest \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.1"
git push
git tag v0.1.1 && git push origin v0.1.1
```

**判断标准**（四条同时成立才算 OIDC 真生效）：

1. `Publish to npm` 输出 `with tag latest and public access`
2. 没有 `ENEEDAUTH`
3. 全程没有任何 OTP 提示
4. 仓库里没有任何 npm token secret（`gh secret list` 应为空）

### 5. 验证结果

```bash
npm dist-tag ls qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

页面：https://www.npmjs.com/package/qiaojin923-npm-cicd-smoke-test

因为是**公开仓库**，`0.1.1` 应该有 **provenance 徽章**；而 `0.1.0`（人工 token 发布）没有。这个对比正好说明「有 trust + public 仓库」才产生 provenance，可以直接拿去评审。

### 6. 测 hotfix 通道

```bash
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.2-hotfix.1 DIST_TAG=hotfix \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.2-hotfix.1"
git push && git tag v0.1.2-hotfix.1 && git push origin v0.1.2-hotfix.1

npm dist-tag ls qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

预期：`latest` 仍是 `0.1.1`，`hotfix` 指向 `0.1.2-hotfix.1`。

### 7. 测失败路径

```bash
# (a) 版本号不一致：改 releases/0.1.1.json 的 version 为 9.9.9
# (b) sha256 不符：改 releases/0.1.1.json 的 sha256 任意一位
# (c) 预发布硬打 latest：打包阶段就会拒绝
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.3-rc.1 DIST_TAG=latest \
  GITHUB_USER=qiaojin923 ./scripts/pack.sh

git commit -am "test: negative case" && git push
git tag -f v0.1.1 && git push origin v0.1.1 --force
```

应有明确的 `::error::`，且失败发生在 Publish 之前。

---

## 已知坑

| # | 坑 | 处理 |
|---|---|---|
| 1 | `gh repo create --source=.` 要求目录已是 git 仓库 | 先 `git init` |
| 2 | `npm publish artifacts/xxx.tgz` 被当成 GitHub 简写 | 加 `./` 前缀或绝对路径 |
| 3 | 新包配 trust 必 403，scoped 包也一样 | 先让包存在 |
| 4 | 发布要求 2FA OTP，脚本/CI 无法代劳 | 首版人工执行，之后走 OIDC |
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

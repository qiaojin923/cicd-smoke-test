# Smoke Test Runbook — 用个人账号验证发布链路

目的：在碰公司账号之前，用**你自己的 GitHub 仓库 + 你自己的 npm 账号**把整条链路跑通，确认没有隐藏问题。

- 包内容：`index.js` + `README.md` + `package.json`，940 字节，无害
- 包名：`qiaojin923-npm-cicd-smoke-test`（已验证可用）
- workflow：与生产**完全相同的文件**，零改动
- 唯一替代：CDN 换成 `raw.githubusercontent.com`（同为匿名可读的 HTTPS 静态地址）

> **顺序很重要**：必须先 `git init` 并打包提交，再做 `gh repo create --source=.`。
> 顺序反了会报 `current directory is not a git repository`。

---

## 前置

```bash
gh auth status || gh auth login        # 浏览器授权一次
node -v && npm -v                      # Node ≥ 22.14，npm ≥ 11.5.1
cd cicd-smoke-test
export GH_USER=$(gh api user -q .login)
```

---

## 步骤

### 1. 初始化 git 并打包

```bash
git init -q && git branch -M main
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.0 DIST_TAG=latest \
  GITHUB_USER="$GH_USER" ./scripts/pack.sh
git add -A && git commit -m "test: scaffold smoke test"
```

`pack.sh` 会做四件事：改写 `pkg/package.json` 的 name/version/repository → `npm pack` → 算 sha256 → 生成 `releases/0.1.0.json`。

### 2. 建公开仓库并推送

**必须 public**：① raw.githubusercontent 才能匿名下载，CI 里不用任何凭证；② 这样才能看到 provenance 长什么样。

```bash
gh auth setup-git
gh repo create "$GH_USER/cicd-smoke-test" --public \
  --description "npm trusted publishing smoke test" \
  --source=. --remote=origin --push
```

### 3. 验证制品可匿名下载（CI 的前置条件）

```bash
curl -fsSL -o /tmp/x.tgz \
  "https://raw.githubusercontent.com/$GH_USER/cicd-smoke-test/main/artifacts/qiaojin923-npm-cicd-smoke-test-0.1.0.tgz"
shasum -a 256 /tmp/x.tgz     # 必须与 releases/0.1.0.json 里的 sha256 一致
```

### 4. 登录你自己的 npm 账号

```bash
npm login --registry https://registry.npmjs.org/
npm whoami --registry https://registry.npmjs.org/     # 确认是你自己
```

### 5. 配置 trusted publisher（一次性，需 2FA）

```bash
npm trust github qiaojin923-npm-cicd-smoke-test \
  --file publish.yml \
  --repository "$GH_USER/cicd-smoke-test" \
  --allow-publish --dry-run --registry https://registry.npmjs.org/

npm trust github qiaojin923-npm-cicd-smoke-test \
  --file publish.yml \
  --repository "$GH_USER/cicd-smoke-test" \
  --allow-publish -y --registry https://registry.npmjs.org/

npm trust list qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

> **这一步就是这个测试要回答的第一个问题（C1）**：包还不存在时，`npm trust` 能不能创建配置。
> 如果报"包不存在"，走兜底：先用一次性 granular token `npm publish ./pkg` 发 0.1.0，回来再配 trust，然后 revoke token。

### 6. 打 tag 触发发布

```bash
git tag v0.1.0 && git push origin v0.1.0
```

打开 Actions 看日志，重点确认：

- `Read release manifest` 输出 `distTag=latest`
- `Verify sha256` 的 expected / actual 一致
- `Publish to npm` 输出 `with tag latest and public access`，**不能**出现 `ENEEDAUTH`

### 7. 验证结果（C3 / C8）

```bash
npm view qiaojin923-npm-cicd-smoke-test version        --registry https://registry.npmjs.org/
npm dist-tag ls qiaojin923-npm-cicd-smoke-test         --registry https://registry.npmjs.org/
npm view qiaojin923-npm-cicd-smoke-test dist.integrity --registry https://registry.npmjs.org/
```

页面：https://www.npmjs.com/package/qiaojin923-npm-cicd-smoke-test
因为是**公开仓库**，这里应该能看到 **provenance 徽章**，点开能看到仓库 / commit / workflow。

### 8. 测 hotfix 通道（C4）

```bash
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.1-hotfix.1 DIST_TAG=hotfix \
  GITHUB_USER="$GH_USER" ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.1-hotfix.1" && git push
git tag v0.1.1-hotfix.1 && git push origin v0.1.1-hotfix.1

npm dist-tag ls qiaojin923-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

预期：`latest` 仍是 `0.1.0`，`hotfix` 指向 `0.1.1-hotfix.1`。**这一步验证「预发版不会顶掉 latest」。**

### 9. 测失败路径（C5 / C6 / C7，验证护栏真的有效）

```bash
# (a) 版本号不一致：把 releases/0.1.0.json 的 version 改成 9.9.9
# (b) sha256 不符：把 releases/0.1.0.json 的 sha256 改任意一位
# (c) 预发布硬打 latest：打包时就会直接报错
PKG_NAME=qiaojin923-npm-cicd-smoke-test VERSION=0.1.2-rc.1 DIST_TAG=latest \
  GITHUB_USER="$GH_USER" ./scripts/pack.sh     # 预期：✗ 预发布版本，DIST_TAG 不能是 latest
```

改完 (a) 或 (b) 后提交，重推同一个 tag 触发：

```bash
git commit -am "test: negative case"
git tag -f v0.1.0 && git push origin v0.1.0 --force
```

Actions 里应看到明确的 `::error::`，且失败发生在 Publish 之前。

---

## 已知坑

**1. `gh repo create --source=.` 必须先有 git 仓库**
否则报 `current directory is not a git repository`。先 `git init` 再建仓库。

**2. `npm publish artifacts/xxx.tgz` 会失败**
含单个斜杠的相对路径会被 npm 当成 GitHub 简写 `owner/repo`，实际执行：

```
npm error command git ls-remote ssh://git@github.com/artifacts/qiaojin923-...tgz.git
npm error git@github.com: Permission denied (publickey).
```

必须加 `./` 前缀：`npm publish ./artifacts/xxx.tgz`。生产 workflow 用绝对路径 `$RUNNER_TEMP/pkg.tgz`，不受影响。

**3. `pack.sh` 的默认版本号取自 `pkg/package.json`**
跑过 hotfix 之后，默认版本会变成预发布版本号，再打包正式版就会触发「预发布不能打 latest」的护栏。显式传 `VERSION=0.1.0` 即可。

**4. 整包 unpublish 后同名 24 小时内不能重新发布**
所以别反复销毁重建，用递增版本号更省事。

---

## 用完清理

```bash
npm unpublish qiaojin923-npm-cicd-smoke-test --force --registry https://registry.npmjs.org/
gh repo delete "$GH_USER/cicd-smoke-test" --yes
```

---

## 这个测试验证不到什么

| 未覆盖 | 原因 | 生产上怎么兜 |
|---|---|---|
| 真实 CDN（download.agora.io） | 无上传权限 | 用 raw.githubusercontent 替代，行为等价（都是匿名 HTTPS + sha256 校验） |
| 公司账号 agora.io 的 owner 权限与 2FA 归属 | 个人账号测不了 | 评审问题第 5 项要求明确 owner + backup |
| 352 KB / 6 文件的大包 | smoke test 只有 940 字节 | 生产的 `npm publish --dry-run` 已验证输出 6 个文件 |
| 私有仓库 → 无 provenance | 测试仓库是 public | 生产方案已按 private 设计，预期本来就没有徽章 |

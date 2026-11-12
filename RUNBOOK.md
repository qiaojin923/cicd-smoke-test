# Smoke Test Runbook — 用个人账号验证发布链路

目的：在碰公司账号之前，用**你自己的 GitHub 仓库 + 你自己的 npm 账号**把整条链路跑通，确认没有隐藏问题。

- 包内容：`index.js` + `README.md` + `package.json`，932 字节，无害
- 包名：`agora-npm-cicd-smoke-test`（已被测可用；建议改成 `<你的npm用户名>-smoke-test` 避免占用公共命名空间）
- workflow：与生产**完全相同的文件**，零改动
- 唯一替代：CDN 换成 `raw.githubusercontent.com`（同为匿名可读的 HTTPS 静态地址）

---

## 前置

```bash
gh auth status || gh auth login        # 浏览器授权一次
node -v && npm -v                      # Node ≥ 22.14，npm ≥ 11.5.1
```

---

## 步骤

### 1. 建公开仓库并推送

**必须 public**：① raw.githubusercontent 才能匿名下载，CI 里不用任何凭证；② 这样才能看到 provenance 长什么样。

```bash
cd cicd-smoke-test
export GH_USER=$(gh api user -q .login)
gh repo create "$GH_USER/cicd-smoke-test" --public \
  --description "npm trusted publishing smoke test" \
  --source=. --remote=origin --push
```

### 2. 登录你自己的 npm 账号

```bash
npm login --registry https://registry.npmjs.org/
npm whoami --registry https://registry.npmjs.org/     # 确认是你自己
```

### 3. 配置 trusted publisher（一次性）

```bash
npm trust github agora-npm-cicd-smoke-test \
  --file publish.yml \
  --repository "$GH_USER/cicd-smoke-test" \
  --allow-publish --dry-run --registry https://registry.npmjs.org/

npm trust github agora-npm-cicd-smoke-test \
  --file publish.yml \
  --repository "$GH_USER/cicd-smoke-test" \
  --allow-publish -y --registry https://registry.npmjs.org/

npm trust list agora-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

> **这一步就是这个测试要回答的第一个问题**：包还不存在时，`npm trust` 能不能创建配置。
> 如果报"包不存在"，走兜底：先用一次性 granular token `npm publish ./pkg` 发 0.1.0，回来再配 trust，然后 revoke token。

### 4. 打包并推送

```bash
GITHUB_USER="$GH_USER" ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.0" && git push
```

### 5. 打 tag 触发发布

```bash
git tag v0.1.0 && git push origin v0.1.0
```

然后打开仓库 Actions 页面看日志，重点确认：

- `Read release manifest` 输出的 `distTag=latest`
- `Verify sha256` 打印的 expected / actual 一致
- `Publish to npm` 输出 `with tag latest and public access`（**不能**出现 `ENEEDAUTH`）

### 6. 验证结果

```bash
npm view agora-npm-cicd-smoke-test version       --registry https://registry.npmjs.org/
npm dist-tag ls agora-npm-cicd-smoke-test        --registry https://registry.npmjs.org/
npm view agora-npm-cicd-smoke-test dist.integrity --registry https://registry.npmjs.org/
```

页面：https://www.npmjs.com/package/agora-npm-cicd-smoke-test
因为是**公开仓库**，这里应该能看到 **provenance 徽章**，点开能看到仓库 / commit / workflow。

### 7. 测第二个通道（hotfix）

```bash
GITHUB_USER="$GH_USER" VERSION=0.1.0-hotfix.1 DIST_TAG=hotfix ./scripts/pack.sh
git add -A && git commit -m "test: 0.1.0-hotfix.1" && git push
git tag v0.1.0-hotfix.1 && git push origin v0.1.0-hotfix.1

npm dist-tag ls agora-npm-cicd-smoke-test --registry https://registry.npmjs.org/
```

预期：`latest` 仍指向 `0.1.0`，`hotfix` 指向 `0.1.0-hotfix.1`。**这一步验证「预发版不会顶掉 latest」。**

### 8. 测失败路径（重要，验证护栏真的有效）

故意制造三种错误，每一种都必须在 **publish 之前**失败：

```bash
# (a) 版本号不一致：改 releases/0.1.0.json 里的 version 为 9.9.9
# (b) sha256 不符：改 releases/0.1.0.json 里的 sha256 任意一位
# (c) 预发布硬打 latest：VERSION=0.1.1-rc.1 DIST_TAG=latest ./scripts/pack.sh 应直接报错

git commit -am "test: negative case" && git push
git tag v0.1.0 && git push origin v0.1.0 --force   # 重推同一 tag 触发
```

Actions 里应看到明确的 `::error::` 且 job 失败在 Publish 之前。

---

## 已知坑（本地预演时踩到的）

**`npm publish artifacts/xxx.tgz` 会失败。** 含单个斜杠的相对路径会被 npm 当成 GitHub 简写 `owner/repo`，实际执行的是：

```
npm error command git ls-remote ssh://git@github.com/artifacts/agora-...tgz.git
npm error git@github.com: Permission denied (publickey).
```

**必须加 `./` 前缀**：`npm publish ./artifacts/xxx.tgz`。生产 workflow 用的是绝对路径 `$RUNNER_TEMP/pkg.tgz`，不受影响。

---

## 用完清理

```bash
npm unpublish agora-npm-cicd-smoke-test --force --registry https://registry.npmjs.org/
gh repo delete "$GH_USER/cicd-smoke-test" --yes
```

注意：整包 unpublish 后，**同名包 24 小时内无法重新发布**。所以测试版本号不要反复用同一个。

---

## 这个测试验证不到什么

| 未覆盖 | 原因 | 生产上怎么兜 |
|---|---|---|
| 真实 CDN（download.agora.io） | 无上传权限 | 用 raw.githubusercontent 替代，行为等价（都是匿名 HTTPS + sha256 校验） |
| 公司账号 agora.io 的 owner 权限与 2FA 归属 | 个人账号测不了 | 评审问题第 6 项要求明确 owner + backup |
| 352 KB / 6 文件的大包 | smoke test 只有 932 字节 | 生产的 `npm publish --dry-run` 已验证输出 6 个文件 |
| 私有仓库 → 无 provenance | 测试仓库是 public | 生产方案已按 private 设计，预期本来就没有徽章 |

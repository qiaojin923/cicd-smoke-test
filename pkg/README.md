# agora-npm-cicd-smoke-test

**这不是一个可用的软件包**，仅用于验证 npm Trusted Publishing（OIDC）流水线是否正常工作。

发布的每一版都只包含 `index.js` 和这份 README，用来确认：

- GitHub Actions 能通过 OIDC 换取 npm 短期凭证
- 版本号、tag、制品 sha256 三方一致性校验生效
- `--tag` 指定的 dist-tag（latest / hotfix）落到正确通道

验证完成后可用 `npm unpublish` 删除。

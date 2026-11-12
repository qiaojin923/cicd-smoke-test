#!/usr/bin/env bash
# 打一个测试包、放到 artifacts/、生成版本清单
# 用法：
#   GITHUB_USER=qiaojin ./scripts/pack.sh
#   GITHUB_USER=qiaojin VERSION=0.1.1 DIST_TAG=hotfix ./scripts/pack.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GITHUB_USER="${GITHUB_USER:-}"
GITHUB_REPO="${GITHUB_REPO:-cicd-smoke-test}"
PKG_NAME="${PKG_NAME:-}"
VERSION="${VERSION:-}"
DIST_TAG="${DIST_TAG:-latest}"

[ -n "$GITHUB_USER" ] || { echo "✗ 需要设置 GITHUB_USER，例如 GITHUB_USER=qiaojin ./scripts/pack.sh"; exit 1; }

# 从 pkg/package.json 读取默认值
PKG_NAME="${PKG_NAME:-$(node -p "require('./pkg/package.json').name")}"
VERSION="${VERSION:-$(node -p "require('./pkg/package.json').version")}"

# 预发布版本不允许打成 latest
case "$VERSION" in
  *-*) [ "$DIST_TAG" = "latest" ] && { echo "✗ 版本 $VERSION 是预发布版本，DIST_TAG 不能是 latest"; exit 1; } ;;
esac

echo "→ 包名   : $PKG_NAME"
echo "→ 版本   : $VERSION"
echo "→ 通道   : $DIST_TAG"
echo "→ 仓库   : $GITHUB_USER/$GITHUB_REPO"

# 1) 同步 package.json
node -e '
  const fs = require("fs");
  const p = "pkg/package.json";
  const pkg = JSON.parse(fs.readFileSync(p, "utf8"));
  pkg.name = process.argv[1];
  pkg.version = process.argv[2];
  pkg.repository = {
    type: "git",
    url: `git+https://github.com/${process.argv[3]}/${process.argv[4]}.git`
  };
  fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + "\n");
' "$PKG_NAME" "$VERSION" "$GITHUB_USER" "$GITHUB_REPO"

# 2) 打包
rm -f ./*.tgz pkg/*.tgz 2>/dev/null || true
(cd pkg && npm pack --silent >/dev/null)
TGZ_NAME="${PKG_NAME}-${VERSION}.tgz"
mkdir -p artifacts
rm -f "artifacts/$TGZ_NAME"
mv "pkg/$TGZ_NAME" "artifacts/$TGZ_NAME"

# 3) 计算校验和
SHA=$(shasum -a 256 "artifacts/$TGZ_NAME" | cut -d' ' -f1)

# 4) 生成版本清单
mkdir -p releases
cat > "releases/${VERSION}.json" <<JSON
{
  "name": "${PKG_NAME}",
  "version": "${VERSION}",
  "distTag": "${DIST_TAG}",
  "url": "https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/artifacts/${TGZ_NAME}",
  "sha256": "${SHA}"
}
JSON

echo
echo "✓ artifacts/$TGZ_NAME"
echo "  size   : $(wc -c < "artifacts/$TGZ_NAME") bytes"
echo "  sha256 : $SHA"
echo "✓ releases/${VERSION}.json"
cat "releases/${VERSION}.json"
echo
echo "下一步："
echo "  git add -A && git commit -m \"test: $VERSION\" && git push"
echo "  git tag v$VERSION && git push origin v$VERSION"

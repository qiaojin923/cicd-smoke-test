// CI/CD smoke test：只用来验证「tag → 校验 → npm publish」这条链路
module.exports = {
  ok: true,
  purpose: 'npm trusted publishing smoke test',
  version: require('./package.json').version
}

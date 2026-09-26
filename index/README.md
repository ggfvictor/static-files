# 北极熊单页

`index.html` 是独立页面，也是版本号的唯一来源（`release-version`）。

## 发布

1. 修改页面和版本号，检查桌面与窄屏效果，提交所有源码变更。
2. 创建对应版本的标签，例如 `git tag -a v1.0.0 -m "Release v1.0.0"`。
3. 运行 `python3 index/build-release.py --tag v1.0.0`。脚本从已提交的 HEAD 导出页面，生成匹配该提交的 `release.json`、ZIP 包与 SHA-256 校验文件。
4. 推送同一个提交和标签。GitHub Actions 会重新验证并创建 Release。含预发布标识的版本标为 prerelease，其余标为正式版。

生成物位于被忽略的 `releases/<version>/`，相同版本禁止覆盖。

## 部署

从 GitHub Release 下载 ZIP，将其中的 `index.html` 和 `release.json` 一起部署到同一目录。直接拉取源码只会得到显示 `local` 的页面；需要先执行上述打包步骤。

元数据请求携带当前版本参数，并使用 `no-store`。服务端也应为 `release.json` 设置 `Cache-Control: no-store`；如配置代理缓存，其缓存键需包含查询参数。升级时同步替换两个文件。

`release.json` 和发布包不参与 Git 提交，避免把提交号写回源码引起 SHA 改变。

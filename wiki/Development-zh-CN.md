# 开发

[English](Development)

### 工具链

Copia 面向 macOS 27，使用 Xcode 27.2 工具链通过 SwiftPM 构建。仅有 Command Line Tools 时缺少 SwiftUI 和 SwiftData 的宏插件，因此请把 `DEVELOPER_DIR` 指向 Xcode：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

唯一的依赖是 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)，固定为 3.1.0。

### 构建与测试

```sh
swift build
swift test
swift build -c release --arch arm64 --arch x86_64
```

测试使用 Swift Testing，不需要任何环境变量。存储测试在临时目录中运行，并使用可注入故障的 `FileOps`。

### 查看效果

- `swift run copia-render --output renders`：把卡片栏的每种状态作为真实窗口放在固定壁纸上，截图到 `renders/` 供设计评审。加 `--only NAME` 只渲染一种状态。需要为终端授予屏幕录制权限。`--only icon-review` 只生成 `12-icon-review.png`：`Resources/AppIcon.icon` 的应用图标以 1024、128、32 和 16 像素分别放在浅色行和深色行上，由 Icon Composer 的导出图合成，不开窗口，也不截屏。
- `scripts/readme-media.sh`：用测试数据把 README 的截图和图标渲染到 `.github/media/`（WebP，浅色和深色）。它会用生成的壁纸盖住主显示器左上角约一分钟，因此只截到 Copia 自己的窗口。另外需要 `cwebp`。
- `Copia --selftest out.json`：通过与 ⌘Y 相同的路径，在每个显示器上打开并关闭卡片栏十次，记录键窗口、前台应用和面板所在的屏幕。只要有违例就以非零状态退出。

### 应用包与图标

`scripts/build-app.sh` 构建通用 release 二进制文件并组装 `dist/Copia.app`。应用包含有 KeyboardShortcuts 资源包，以及由 `actool` 从 `Resources/AppIcon.icon` 编译的图标。随后脚本使用 Apple Development 身份签名；如果二进制文件不同时包含 arm64 和 x86_64 两个架构就失败（`scripts/check-archs.sh`）；最后生成 `dist/Copia-0.0.1.zip`。在 CI 中使用 `--unsigned`。

图标是一个 Icon Composer 包：三层 SVG 卡片位于柿橙到覆盆子红的渐变之上。macOS 27 会加上 Liquid Glass 材质、高光以及深色和着色变体。可用 `swift scripts/render-icon.swift dist/Copia.app icon.png` 预览。

### CI

`.github/workflows/ci.yml` 在每次推送时于 `xcode-27` runner 上运行。它检查 wiki 和发布脚本的自测，运行通用构建、测试和基准测试，并组装未签名的应用包。Actions 固定到提交 SHA。

### Wiki

`wiki/` 是唯一的文档。每个页面都有英文 `Page.md` 和中文 `Page-zh-CN.md`，标题层级相同。两个文件的第 3 行互相链接对方语言。页面之间用页面名链接，`_Sidebar.md` 列出两种语言的所有页面。`python3 scripts/check-wiki.py` 负责检查这些规则，`--self-test` 证明每项检查都会在对应的样例上失败。每次推送到 `main` 后，`.github/workflows/publish-wiki.yml` 会把 `wiki/` 同步到 GitHub Wiki。没有 `docs/` 文件夹，也没有更新日志。

### 发布

发布版由 GitHub Actions 构建并签名，不会从本地 `dist/` 上传任何文件。推送标签之前，先在本地用同一份证书构建并签名同一个提交并手动验证；验证通过后才推送标签。

1. CI 通过后合并发布用的拉取请求，然后检出合并后的提交：`git switch main && git pull`。
2. 构建并签名：`scripts/build-app.sh`。它使用 Apple Development 身份签名，因此证书必须在你的钥匙串中；如果二进制文件不同时包含 arm64 和 x86_64 两个架构，它会失败。
3. 像浏览器下载那样给构建加上隔离标记，并确认已设置：`xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Copia;" dist/Copia.app`，然后 `xattr -p com.apple.quarantine dist/Copia.app` 必须输出这个值。
4. 运行 `spctl -a -vv dist/Copia.app`，把完整输出贴到发布用的拉取请求中。这个构建没有经过公证，因此预计 Gatekeeper 会拒绝它；这份记录说明发布的是哪种结果。
5. 打开这个带隔离标记的 `dist/Copia.app`。首次启动时 macOS 会阻止它：在“系统设置 → 隐私与安全性”中点击 **仍要打开**。确认快捷键录制器能显示文字。
6. 在这个应用上手动检查：在文本编辑中复制，然后 ⌘Y 加 ↩ 能粘贴；图片和链接卡片显示已保存的预览；删除卡片会把它的文件从 `~/Library/Application Support/Copia` 中移除；全新的引导在授予辅助功能权限后会更新；登录时启动的状态能读回；重新绑定的快捷键会替换旧的；设置显示 通用、快捷键、隐私 三个标签页，**清除历史** 会先询问，点“取消”会保留历史；卡片栏能在全屏应用上方打开。
7. 只有上面每一步都通过后，才给同一个提交打标签：`git tag v0.0.1 && git push origin v0.0.1`。`.github/workflows/release.yml` 会运行测试、构建通用应用、用 `release` 环境中保存的证书签名并验证，然后把 `Copia-0.0.1.zip` 及其 SHA-256 发布为 GitHub Release。日志中会再次显示已发布构建的 `spctl -a -vv` 结果。
8. 把发布的 zip 下载到一个新的临时文件夹，用 `shasum -a 256` 与发布的 `.sha256` 比对，并在那里打开一次。

一次性签名设置（在推送第一个标签之前）：在“钥匙串访问”中，只把“Apple Development”证书连同私钥导出为带密码的 `.p12`，然后在终端中运行 `scripts/setup-release-signing.sh path/to/certificate.p12`。它会让 `release` 环境只接受 `v*` 标签：删除其他所有部署策略，缺少时添加这一条；只要有一次策略调用失败或还留有其他策略，它就在保存任何密钥之前停止。之后它把证书和密码存为该环境的密钥，并以不回显的方式询问密码。`scripts/test-setup-release-signing.sh` 用假的 `gh` 检查这些行为。完成后删除 `.p12`。拉取请求和分支构建永远看不到这些密钥；CI 中的构建不签名。

这个构建使用 Apple Development 证书签名，因此各个版本保持同一身份（更新后辅助功能权限仍然有效），但没有经过公证。公证需要付费 Apple Developer Program 提供的 Developer ID 证书。

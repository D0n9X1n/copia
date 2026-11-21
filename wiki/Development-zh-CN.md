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

- `swift run copia-render --output renders`：把卡片栏的每种状态作为真实窗口放在固定壁纸上，截图到 `renders/` 供设计评审。加 `--only NAME` 只渲染一种状态。需要为终端授予屏幕录制权限。
- `scripts/readme-media.sh`：用测试数据把 README 的截图和图标渲染到 `.github/media/`（WebP，浅色和深色）。它会用生成的壁纸盖住主显示器左上角约一分钟，因此只截到 Copia 自己的窗口。另外需要 `cwebp`。
- `Copia --selftest out.json`：通过与 ⌘Y 相同的路径，在每个显示器上打开并关闭卡片栏十次，记录键窗口、前台应用和面板所在的屏幕。只要有违例就以非零状态退出。

### 应用包与图标

`scripts/build-app.sh` 构建通用 release 二进制文件并组装 `dist/Copia.app`。应用包含有 KeyboardShortcuts 资源包，以及由 `actool` 从 `Resources/AppIcon.icon` 编译的图标。随后脚本使用 Apple Development 身份签名，并生成 `dist/Copia-0.0.1.zip`。在 CI 中使用 `--unsigned`。

图标是一个 Icon Composer 包：三层 SVG 卡片位于柿橙到覆盆子红的渐变之上。macOS 27 会加上 Liquid Glass 材质、高光以及深色和着色变体。可用 `swift scripts/render-icon.swift dist/Copia.app icon.png` 预览。

### CI

`.github/workflows/ci.yml` 在每次推送时于 `xcode-27` runner 上运行。它检查 wiki，运行通用构建、测试和基准测试，并组装未签名的应用包。Actions 固定到提交 SHA。

### Wiki

`wiki/` 是唯一的文档。每个页面都有英文 `Page.md` 和中文 `Page-zh-CN.md`，标题层级相同。两个文件的第 3 行互相链接对方语言。页面之间用页面名链接，`_Sidebar.md` 列出两种语言的所有页面。`python3 scripts/check-wiki.py` 负责检查这些规则，`--self-test` 证明每项检查都会在对应的样例上失败。每次推送到 `main` 后，`.github/workflows/publish-wiki.yml` 会把 `wiki/` 同步到 GitHub Wiki。没有 `docs/` 文件夹，也没有更新日志。

### 发布

1. CI 通过后合并发布用的拉取请求。
2. 运行 `scripts/build-app.sh`，并用 `codesign --verify --deep --strict dist/Copia.app` 验证。
3. 打标签 `v0.0.1` 并运行 `gh release create v0.0.1 dist/Copia-0.0.1.zip`。

# 开发

[English](Development)

### 工具链

Copia 面向 macOS 26 及以上版本的 arm64 和 x86_64，使用 Xcode 27.2 工具链通过 SwiftPM 构建。仅有 Command Line Tools 时缺少 SwiftUI 和 SwiftData 的宏插件，因此请把 `DEVELOPER_DIR` 指向 Xcode：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

唯一的依赖是 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)，固定为 3.1.0。

### 构建与测试

```sh
swift build
swift test
scripts/test-release-tools.sh
swift build -c release --arch arm64 --arch x86_64
```

测试使用 Swift Testing，不需要任何环境变量。存储测试在临时目录中运行，并使用可注入故障的 `FileOps`。

### 查看效果

- `swift run copia-render --output renders`：把卡片栏的每种状态作为真实窗口放在固定壁纸上，截图到 `renders/` 供设计评审。加 `--only NAME` 只渲染一种状态。需要为终端授予屏幕录制权限。`--only icon-review` 只生成 `12-icon-review.png`：`Resources/AppIcon.icon` 的应用图标以 1024、128、32 和 16 像素分别放在浅色行和深色行上，由 Icon Composer 的导出图合成，不开窗口，也不截屏。
- `scripts/readme-media.sh`：用测试数据把 README 的截图和图标渲染到 `.github/media/`（WebP，浅色和深色）。它会用生成的壁纸盖住主显示器左上角约一分钟，因此只截到 Copia 自己的窗口。另外需要 `cwebp`。
- `"$(swift build --show-bin-path)/Copia" --selftest out.json`：枚举显示器，在每个屏幕上开关卡片栏十次，不移动实际指针，事件只发给测试面板。检查面板是否复用、焦点、位置、输入与关闭后的清理；随后从未激活的后台应用打开一次设置，确认设置窗口既是键窗口也是主窗口。包验证要求报告为 schema 4、`settingsFirstAction: true`、循环数完整且无违例。存储、偏好设置和剪贴板均为测试专用；由于会打开真实窗口，请在空闲桌面上运行。

### 应用包与图标

`scripts/build-app.sh` 构建通用 release 二进制文件并组装 `dist/Copia.app`。应用包含有 KeyboardShortcuts 资源包，以及由 `actool` 从 `Resources/AppIcon.icon` 编译的图标。随后脚本使用 Apple Development 身份签名；如果二进制文件不同时包含 arm64 和 x86_64 两个架构就失败（`scripts/check-archs.sh`）；最后生成 `dist/Copia-<VERSION>.zip`。在 CI 中使用 `--unsigned`。

Garland 图标是一个 Icon Composer 包：三张卡片用黄色夹子挂在弧线上，背景为紫色渐变。六层 SVG 分别绘制卡片、卡片细节、夹子和弧线。macOS 会加上 Liquid Glass 材质和高光。浅色与深色外观都使用选定的浅色图案：紫色背景和白色卡片。可用 `swift scripts/render-icon.swift dist/Copia.app icon.png` 预览。

### CI

`.github/workflows/ci.yml` 在拉取请求和推送到 `main` 时（不含推送标签）于 `xcode-27` runner 上运行。它检查 wiki 和发布脚本的自测，运行通用构建、测试和基准测试，并检查未签名 ZIP 内的资源、版本、架构集合及各架构的最低系统版本，随后运行解压所得原生可执行文件的 `--selftest`。Actions 固定到提交 SHA。如果基准测试失败，会另行运行有时限的 Time Profiler，仅分析 `copia-bench`，并将 `failure-profile` 产物保留七天。插桩后的数值仅用于诊断，绝不替代未插桩且已失败的门槛检查。

### Wiki

`wiki/` 是唯一的文档。每个页面都有英文 `Page.md` 和中文 `Page-zh-CN.md`，标题层级相同。两个文件的第 3 行互相链接对方语言。页面之间用页面名链接，`_Sidebar.md` 列出两种语言的所有页面。`python3 scripts/check-wiki.py` 负责检查这些规则，`--self-test` 证明每项检查都会在对应的样例上失败。每次推送到 `main` 后，`.github/workflows/publish-wiki.yml` 会把 `wiki/` 同步到 GitHub Wiki。没有 `docs/` 文件夹，也没有更新日志。

### 发布

稳定版标签必须为 `v` 加上仓库 `VERSION` 文件中的完整版本号。发布 PR 和所有关联议题必须属于该标签的里程碑。合并到 `main` 后，等待合并 SHA 对应的 main 推送通过 **CI** 和 **Publish wiki**。PR 检查、手动运行及旧的成功记录都不能代替它。

1. 打标签前，在空闲的测试 Mac 上验证带隔离标记的应用，记录实际的 `spctl -a -vv` 结果及「仍要打开」的结果。检查复制后手动 ⌘V、快捷键标签、设置入口、预览和全屏。记录实际系统、硬件及显示器；不能用架构检查代替原生 Intel、Rosetta、macOS 26 或 120 Hz 实测。
2. 在验证过的提交上打 `v$(cat VERSION)` 标签。只读预检验证完整提交历史、前一稳定标签、精确 SHA 的最新 main 推送及必需作业、未插桩的基准报告、已合并 PR、里程碑及议题状态。仓库只要还有未关闭的议题（不包括 PR），就不能发布；不要为了放行而关闭无关议题。
3. 预检通过后，签名作业才能使用现有的 `release` 环境；该环境只允许来自 `v*` 标签的部署。这项环境限制不等于仓库标签规则集，也不代表必须有人审核。作业使用现有 Apple Development 身份（团队 `AV5CFZA3T3`）签名。签名作业移除临时钥匙串，在全新目录验证 ZIP 的安全时间戳、资源和两个架构的 macOS 26.0 部署下限，并运行包内原生 `--selftest`。
4. 独立的发布作业按不可变产物 ID 和摘要下载，验证两个上传文件，先创建草稿，再复查草稿文件摘要和实时发布证据才公开。发布说明列出里程碑中的每个议题：仅将本次范围内由未被撤销的变更关闭的议题计为已解决；其他关闭原因另外列明。检查失败时不会公开发布，请检查失败的作业，不要替换证据。
5. 发布后，把 ZIP 和 `.sha256` 下载到新的空目录，核对摘要后再打开。Apple Development 签名**不等于公证**；发布流程不申请证书，也不修改密钥。

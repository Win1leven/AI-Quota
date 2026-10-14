# 首个公开测试版实施计划

目标：v0.1.0-beta.1 可从 GitHub 直接下载，不要求编译应用；保留现有 Provider → QuotaStore → SwiftUI 架构和账户授权边界。
用户于 2026-10-14 授权图标设计、整合、打包与发布。既有视觉方向已接受，图标采用青绿双弧额度环，Codex/Claude 双服务共享一个圆环；不新增 UI 流程。

- [x] 独立审查 b80410f..cf3d32e，运行全部 52 个合成测试，确认现有四个叠加 PR 可整合。
- [x] 图像生成 1024px 应用图标；以系统 sips/iconutil 生成 icns，配置 CFBundleIconFile。原图和 icns 入 Git，生成 app/DMG/ZIP 不入 Git。
- [x] 扩展现有 build.sh/make-dmg.sh；使用唯一临时 staging、新源码 release build、arm64/x86_64 Universal 二进制、ad-hoc 签名、版本 0.1.0（build 1），输出到 dist。无 Developer ID 证书，不宣称已公证。
- [x] README 中文首页，docs/USAGE.zh-CN.md 安装/两种 Claude 来源/桌面胶囊/刷新/缓存/卸载；docs/releases/v0.1.0-beta.1.md 列出环境、验证、残余边界。
- [x] 修正 About 中旧固定版本和过度隐私宣称，复用 Bundle 信息与现有图标，不改变凭据访问行为。
- [x] 构建两架构；验证 Mach-O 版本、依赖、签名、图标、DMG 与 ZIP 内容一致且无私有数据；临时复制安装到干净目录并验证。对干净账户启动使用隔离文件/网络环境，不影响当前运行应用及真实配置。
- [x] 请求独立发布差异审查；修复 P1/P2 后顺序合并 PR #2→#5，发布差异另建 PR 并合并。
- [x] 在最终 main 提交上创建 v0.1.0-beta.1 tag 与 GitHub prerelease，附 DMG/ZIP/SHA256SUMS；匿名 API 与下载校验，更新 Issue #1 和项目进度。

约束：不新增依赖，不改 CI，不上传凭据、个人使用历史或产品推广视频。Claude 桌面会话功能默认关闭，用户自行选择开启。Codex CLI 是数据源依赖；可选 Claude Code collector 需要 python3，桌面方式无需它。Intel 仅编译及静态验证，实际运行验证仅本机 Apple Silicon。真实重置边界仍是后续接受项。

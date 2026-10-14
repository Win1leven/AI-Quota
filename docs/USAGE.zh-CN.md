# AI-Quota 中文使用说明

## 安装与更新

要求 macOS 13 或更新版本。v0.1.0-beta.1 的 Universal 安装包同时包含 Apple Silicon（arm64）与 Intel（x86_64）。实际运行验证在 Apple Silicon 上完成，Intel 尚未在真机验证。

从 [GitHub 测试版页面](https://github.com/Win1leven/AI-Quota/releases/tag/v0.1.0-beta.1) 下载 DMG，打开后把 **AI-Quota.app** 拖进 **Applications**。也可以下载 ZIP，解压后手动移入应用程序。不需要安装开发工具来运行本应用。

测试版尚无 Developer ID 分发签名和 Apple 公证。若首次启动被拦截，先尝试打开一次，再到“系统设置 → 隐私与安全性 → 仍要打开”，在再次提示中选择“打开”。这是针对该应用的单独例外，**不需要关闭整个系统门禁**。仅在确认下载来自本仓库、文件未被篡改时继续。若提示应用损坏或会损坏电脑，不要忽略，重新核验文件并提交问题。[Apple 官方说明](https://support.apple.com/zh-cn/102445)。企业管理设备可能不允许此操作。

可下载同版本 SHA256SUMS，并在下载目录执行：

```sh
shasum -a 256 AI-Quota-0.1.0-beta.1-universal.dmg
```

将输出与 SHA256SUMS 中该文件的值比较。SHA256 校验完整性，不代表 Apple 公证。

更新时先从菜单栏右键或胶囊右键菜单退出旧应用，再替换应用程序中的 app。Bundle Identifier 保持 `com.opencode.aiquota`，已保存的设置沿用。当前不自动更新。

## 找到界面和设置

应用启动后默认显示在右上菜单栏，没有普通主窗口。点击查看两项额度，右键打开 **Settings**。应用激活后也可以使用 `⌘,`。

Settings → **General → Display**：

- **Menu bar only**：只显示菜单栏。
- **Desktop assistant only**：只显示桌面胶囊。
- **Menu bar and desktop assistant**：同时显示。

桌面胶囊显示两个服务各自所有已知窗口中最小的剩余额度。点击打开详情；拖动保存位置；右键可以刷新、打开 Settings 或退出。橙色点表示缓存或刷新警告。没有数据时保留未知状态，不当作 0%。详情支持紧凑/完整切换。

## 配置 Codex

需要 **Codex CLI** 已安装并登录；使用 AI-Quota 无需粘贴 API Key 或 token。本应用不安装 Codex、也没有账号登录页。

1. 在终端确认 `codex --version` 可运行，并完成 Codex 的正常登录。
2. Settings → **Codex**，检查检测到的路径。
3. 自动查找失败时，在终端执行 `which codex`，将该可执行文件的完整路径填写在设置中的自定义路径框。
4. 刷新 Codex，确认服务返回的窗口、剩余额度与重置时间。

自动发现覆盖 Homebrew 常见路径，并尝试登录 shell 的 PATH。不要假定任意 Codex 桌面应用都会被自动识别；无法识别时使用 CLI 自定义路径。账户可能只返回周窗口，这不表示应用应推算或补出 5 小时额度。

## 配置 Claude：只使用桌面端

1. 安装并登录 Claude 桌面应用。
2. Settings → **Claude**，开启 **Read quota and reset times from desktop login**。
3. 如果 macOS 询问 Claude Safe Storage 的钥匙串访问，按自己的授权意愿允许或拒绝。拒绝后应用显示警告，并保留本地历史或上次有效样本。
4. 刷新 Claude。接口返回的 5 小时/周额度与重置时间会显示在详情中，来源为桌面账户。

该开关**默认关闭**。关闭时不读取桌面会话凭据；本地桌面使用历史只能提供缓存百分比，不包含重置日期。开启后读取必要的本地 Claude Cookie 和指定的 Safe Storage 钥匙串项，仅向固定的 `claude.ai` usage 接口发送会话 Cookie。AI-Quota 不保存凭据，不发送聊天内容。

如果 Claude 自己的使用量页面显示“等待第一条消息”，说明 5 小时窗口尚未开始。应用也会显示等待状态；在桌面端完成一次正常使用、账户返回重置时间后恢复倒计时。无需为了本应用转去 Claude Code。

## 配置 Claude Code（可选）

此方式独立于桌面会话访问，不要求开启上述开关。

1. 确认 Claude Code 可用，并且其运行环境的 PATH 中有 `python3`。
2. Settings → **Claude → Claude Code Status Line Collector → Install / Enable**。
3. 重启 Claude Code，完成一次正常回复。采集器在 Claude Code 活动时取得状态栏提供的额度数据。
4. 闲置时显示缓存和原采样时间；若服务未提供重置字段，该字段保留未知。

安装仅修改 `~/.claude/settings.json` 中的 statusLine，保留原有显示命令并保存恢复记录。不会自动改动其他设置。若检测到未知自定义包装或恢复冲突，应用会拒绝替换，请先查看提示。

关闭采集器用 **Restore Original Config**。它恢复已保存的原状态栏，既有配额样本仍可作为缓存显示。不要通过删除整个 Claude 设置文件卸载采集器。

## 刷新、缓存与统计

- `Live`、`Recent sample`、`Sampled just now` 表示近期样本，不承诺每秒同步。
- `Cached` 和 `Stale` 表示缓存/过期；以 **Sampled** 时间判断数据新旧。
- 接口失败会尽可能保留最近的有效数据并显示警告，不能将缓存误认为最新额度。
- 重置时间只来自服务返回，API 缺字段或窗口未开始时不推算。
- 本地 token 统计、API 等价美元估算不是订阅剩余额度，也不是实际账单。
- History 设置支持保留周期和清除历史，清除后会记录导入截止时间，避免立即导回已清除数据。

## 常见问题

| 现象 | 排查方式 |
| --- | --- |
| 打开后没有窗口 | 先看菜单栏；桌面模式时看胶囊，右键进入设置。 |
| Codex not found | 确认 CLI 已安装且可运行，设置 `which codex` 返回的路径。 |
| Codex timeout / quota unavailable | 使用 Codex 官方客户端检查登录/网络，稍后刷新；缓存仍会保留。额度接口失败不一定是登录失效。 |
| Claude 只有缓存，没有重置 | 桌面会话开关是否开启、桌面是否已登录；桌面历史不存重置日期。 |
| Claude 等待第一条消息 | 对照 Claude 自己的使用量页面；开始窗口后再刷新。 |
| Claude 桌面 usage 被拒绝 | 在 Claude 桌面重新登录，检查钥匙串授权；私有接口或 Cookie 格式变化时可能暂不兼容。 |
| Claude Code 采集器等待样本 | 完成一次正常回复，检查运行环境的 python3；桌面回复不会触发 Code 状态栏。 |
| 开机启动选项不可用 | 首个测试版尚未支持，手动打开应用即可。 |

反馈请在 [Issues](https://github.com/Win1leven/AI-Quota/issues) 提供 macOS 版本、芯片、应用版本与错误提示。About → **Copy Diagnostic Summary** 包含配额和时间信息，分享前自行检查或删去不想公开的部分。**不要提交 Cookie、Keychain 内容、token、原始会话记录或 auth 文件。**

## 本地数据与卸载

额度与应用设置存在该应用的 macOS UserDefaults 中；本地历史位于 `~/Library/Application Support/AIQuota/`。Claude 桌面使用历史来自其自己的数据目录，AI-Quota 不负责删除。

若启用了 Claude Code 采集器，先在应用里使用 **Restore Original Config**，确认恢复成功后退出应用。然后把“应用程序”中的 **AI-Quota.app** 移到废纸篓即可。卸载 app 不会自动删除本地历史与偏好设置。需要清除时先使用 History 的清除操作，或备份后单独处理 AIQuota 数据目录；不要删除 `.claude` 或 Claude 桌面的数据目录。

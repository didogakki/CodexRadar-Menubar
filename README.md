# CodexRadar

非官方 macOS 菜单栏小工具，监控 OpenAI 各模型在「降智雷达 / Model-IQ」基准上的实时表现。
原生实现设计稿「方案 B · 评分条」：`NSStatusItem` + `NSPopover`，弹窗内容用 `NSHostingController` 承载 SwiftUI。

## 项目性质

这是一个基于 [Codex 雷达](https://codexradar.com/)公开数据接口制作的非官方客户端，方便在 macOS 菜单栏里快速查看当前模型评分、24h 重置概率和更新时间。

本项目不隶属于、也不代表 Codex 雷达网站、OpenAI 或其他第三方。网站名称、数据、商标和相关内容归各自权利人所有；本仓库的开源许可证只覆盖这里的应用源码。

## 环境要求

- macOS 13+（部署目标）
- Xcode 15+（Swift 5.9+）
- [XcodeGen](https://github.com/yonyz/XcodeGen)：`brew install xcodegen`

## 构建与运行

```bash
xcodegen generate                 # 由 project.yml 生成 CodexRadar.xcodeproj
open CodexRadar.xcodeproj          # 在 Xcode 里 ⌘R 运行
```

或纯命令行：

```bash
xcodegen generate
xcodebuild -project CodexRadar.xcodeproj -scheme CodexRadar -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/CodexRadar.app
```

运行后图标出现在菜单栏右侧（`LSUIElement = YES`，无 Dock 图标）。点击图标弹出 popover。

Debug 构建后会自动渲染 SwiftUI 预览状态截图到 `build/preview-renders/`，包括成功、加载、错误和汇总对比图；也可以手动运行：

```bash
Tools/render_preview_states.sh
```

## 数据来源与三条关键规则

接口：`https://codexradar.com/current.json`（启动拉取一次 + 每 5 分钟轮询 + ⌘R 手动刷新）。

为了尽量温和地使用上游服务，应用只请求公开 JSON 接口，默认 5 分钟轮询一次，不抓取页面、不提交数据。

1. **更新时间**读 `model_iq.quota_radar.updated_at`（ISO/UTC），按用户当前系统时区显示，并实时展示「距今」。
2. **排序**：智商降序 → 同分先比底座版本（新者优先）→ 再比思考档（低档优先）。
3. **24h 重置**满分 100%，仅 `≥70%` 绿色高亮，否则中性显示。

### 真实接口字段映射（与设计稿语义的差异）

设计稿 `DataModel.swift` 假设的 `model_iq.scoreboard` / `quota_radar.reset_24h` 在真实接口里并不存在，已在 `RadarParser` 做映射：

| 设计语义 | 真实 JSON 路径 |
|---|---|
| 评分列表 | `model_iq.latest` + `model_iq.comparisons.<key>.latest`（拼装） |
| 模型名 / 强度 | `model` / `reasoning_effort` |
| 24h 重置概率 | `prediction.probability_24h`（0…1） |
| 更新时间 | `model_iq.quota_radar.updated_at` ✓ |

## 隐私说明

CodexRadar 会请求公开数据接口 `https://codexradar.com/current.json`。本机系统时区只通过 Foundation 在本地格式化更新时间，不会上传时区名、地理位置或其他设备信息。

通知权限仅用于发送本地测试通知；应用不读取通讯录、日历、定位、照片或麦克风等敏感数据。

## 许可证

本仓库源码采用 [MIT License](LICENSE)。

MIT License 只适用于本仓库代码，不授予任何第三方网站数据、品牌、商标、图标或内容的再授权。

## 工程结构

```
Sources/
├── App/            入口 + AppDelegate（状态栏/弹窗/轮询/通知/快捷键）
├── Model/          解码(CurrentResponse) + 领域模型 + 解析排序(RadarParser)
├── Service/        RadarService（异步拉取）
├── ViewModel/      RadarViewModel（快照/加载/错误/相对时间）
├── Views/          DesignTokens + 各 SwiftUI 视图（方案 B 高保真）
└── Support/        VisualEffectView（深色毛玻璃）
```

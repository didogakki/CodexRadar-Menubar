# CodexRadar

> 非官方 macOS 菜单栏小工具：把一组编码模型（Codex 系列 + Claude Code 系列）在同一套基准任务上的最新跑分，换算成「综合分」，菜单栏直接告诉你「现在综合最优的是哪一个」。

原生实现：`NSStatusItem` + `NSPopover`，弹窗用 `NSHostingController` 承载 SwiftUI。数据来自 [Codex 雷达](https://codexradar.com/) 的公开数据，仅做只读拉取。

<p align="center">
  <img src="docs/screenshot.png" width="320" alt="CodexRadar 弹窗">
</p>

## 功能

- **菜单栏一眼看结论**：彩色圆点 + 综合最优 Codex 的紧凑名 + IQ（如 `● 5.5·medium IQ 87.0`），颜色按 IQ 阈值取色。
- **综合分排名**：IQ / 通过数 / 费用 / 耗时四维几何加权，Codex 与 Claude 各自成榜，组内名次决定行配色。
- **稳定数据源**：Codex 评分走结构化 JSON 端点，不受网站首页改版影响；Claude 参考列尽力而为，抓不到也不影响 Codex。
- **轻量常驻**：无 Dock 图标，启动拉取 + 每 30 分钟轮询，`⌘R` 手动刷新、`⌘O` 打开网站。
- **纯只读、不上传**：只请求两个公开地址，不读取任何本机敏感数据。

## 环境要求

- macOS 13+
- Xcode 15+（Swift 5.9+）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`

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

运行后图标出现在菜单栏右侧（`LSUIElement = YES`，无 Dock 图标），点击弹出 popover。

Debug 构建会自动把弹窗各状态（正常 / 加载 / 错误）渲染到 `build/preview-renders/`；也可手动运行 `Tools/render_preview_states.sh`。

## 数据来源

应用在启动时拉取一次、之后每 30 分钟轮询一次，`⌘R` 可手动刷新。两个公开数据源各司其职：

- **Codex 评分（主源，必需）**：`https://codexradar.com/current.json`，从 `model_iq.latest` 与 `model_iq.comparisons` 取 IQ（`score`）/ 通过数 / 费用（`cost_usd`）/ 耗时（`wall_seconds`，并行墙钟）/ 模型名 / 思考档（`reasoning_effort`）。JSON 是结构化稳定端点，Codex 的展示与排名不受首页改版影响。
- **Claude 评分（best-effort）**：`current.json` 不含 Claude/Opus 字段，故 Claude（Opus 参考列）从首页 `https://codexradar.com/` 的 HTML 对比表解析。HTML 排版易变，**抓取或解析失败都不会影响 Codex**，此时 Claude Code 组提示「数据提取失败」或隐藏。
- **检测时间戳**：`current.json` 的 `model_iq.quota_radar.updated_at`（ISO/UTC），按系统时区显示为 `YYYY-MM-DD HH:mm`，并实时展示「距今」。

> 耗时统一采用 JSON 的 `wall_seconds`（并发跑完的真实墙钟），与网页对比表的「总计算时长」口径不同。

## 综合分算法

四个维度几何加权（值越高越好），**按族各自归一化**——Codex 只和 Codex 比，Claude 只和 Claude 比：

```
maxIq   = 本族内最高 IQ
minCost = 本族内最小费用
minTime = 本族内最小耗时
score   = (iq / maxIq)         ^ 0.42
        × (min(passed,8) / 8)  ^ 0.13
        × (minCost / cost)     ^ 0.30
        × (minTime / time)     ^ 0.15
```

- 进度条宽度 = `round(score × 100)%`，分数保留两位小数；通过数封顶 8，避免 `passed > 8` 把综合分推过 1。
- 分 `Codex` / `Claude Code` 两组，各自按综合分降序排名；组内名次决定行配色（第 1 绿、第 2 黄、第 3 橙、第 4 红）。
- 因按族归一化，每组冠军分数都趋近 1.0，**两组分数不能横向比较**——分数只表示组内排名。Codex 来自 `current.json` 全量评测，Claude（Opus）来自 HTML 参考快照，故各自成榜、互不影响。

## 隐私

只请求 `https://codexradar.com/current.json` 与 `https://codexradar.com/` 两个公开地址，只读拉取、不提交任何数据。系统时区仅用于本地格式化更新时间，不上传时区、定位或其他设备信息；不读取通讯录、日历、定位、照片或麦克风等敏感数据。

## 工程结构

```
Sources/
├── App/        入口 + AppDelegate（状态栏 / 弹窗 / 轮询 / ⌘O·⌘R 快捷键）
├── Model/      领域模型 + 综合分与解析（RadarParser）+ JSON 解码（CurrentResponse）
├── Service/    RadarService（JSON 主源拉 Codex + HTML best-effort 拉 Claude）
├── ViewModel/  RadarViewModel（快照 / 加载 / 错误 / 相对时间）
├── Views/      DesignTokens + 榜单视图 + 头部 / 菜单栏 / 底部
└── Support/    VisualEffectView（深色毛玻璃）
Tests/
└── CodexRadarTests/  RadarParser / RadarService / StatusItemTitle 单元测试
```

## 免责声明

本项目为非官方客户端，不隶属于、也不代表 Codex 雷达网站、OpenAI、Anthropic 或其他第三方。网站名称、数据、商标和内容归各自权利人所有。

## 许可证

[MIT License](LICENSE)。MIT 只适用于本仓库代码，不授予任何第三方网站数据、品牌、商标、图标或内容的再授权。

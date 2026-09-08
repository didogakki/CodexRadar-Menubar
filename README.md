# CodexRadar

> 非官方 macOS 菜单栏小工具：跟随 codexradar.com 的「站长推荐」与「智力效率」权威数据，菜单栏直接告诉你「服务端推荐的日常开发性价比档是哪一个」，并附合并了两个雷达数据源的 Claude Code 分区。

原生实现：`NSStatusItem` + `NSPopover`，弹窗用 `NSHostingController` 承载 SwiftUI。数据来自 [Codex 雷达](https://codexradar.com/) 与 [Claude Code 雷达](https://claudecoderadar.com/) 的公开数据，仅做只读拉取。

<p align="center">
  <img src="docs/screenshot.png" width="320" alt="CodexRadar 弹窗">
</p>

## 功能

- **菜单栏一眼看结论**：彩色圆点 + 服务端 `daily_development` 中首个 GPT 推荐项的紧凑名（如 `● 5.5·medium`），颜色按 IQ 阈值取色；insights 不可用时回退本地估算冠军。
- **场景推荐区**：弹窗顶部固定展示「日常开发」「难题攻坚」两个决策场景，每个场景两行（主推荐 + 备选），型号名不截断、价格与 IQ 右对齐成列。IQ 取 `comprehensive_points` 的综合 IQ —— 也就是推荐排序真正依据的那个值，避免出现「第一名的数字比第二名小」。后台自动化 / 跑龙虾类任务不进推荐区，仍以行内 chip 呈现。
- **权威指标列表**：Codex 列表使用 intelligence-efficiency 的网站 IQ / 价格 / 时长 / 成本指数，一律按 IQ 降序（推荐项不置顶，结论已在顶部推荐区）；命中推荐的行带场景 chip，按场景配色（日常开发蓝 / 难题攻坚紫）且不折叠——一个档位同时命中两个场景是常态。进度条只是 IQ 视觉比例，不是自创总评分。
- **性价比标记**：同一分组内、且同一数据源内比较——若组内存在另一档「IQ 不更低 + 花费更少 + 耗时不超过本档 1.1 倍」，本档即被判为被压制，价格标橙；组内无人能压制的档位价格标绿。被压制且花费达到参照档 2 倍以上时，行内再加一个 `×N` 角标（参照取所有压制者中最便宜的一档）。10% 耗时容差是为了避免「快 1 分钟」让一个贵一倍、IQ 还更低的档位逃脱标记。花费或耗时缺失的档位不参与判定，价格保持中性灰。Claude Code 分区混了两个站点的数据，任务集不同导致花费差一个量级，因此判定再按 `metricSource` 分桶，只在同源内比较（见「Claude Code 分区的两个源合并」）。纯展示层结论，不改排序，也不影响菜单栏选型与场景推荐区。
- **单行分区筛选**：`全部 | OpenAI | Claude Code | Grok | DeepSeek`。分区的顺序与内容都来自 `BoardSection.displayOrder` 这一份来源，筛选行与榜单共用，不会筛出空组；当前快照没有的分区不出现在筛选行里；筛选 chip 横向可滚，右端固定「只看前沿」开关（见下）。Codex 侧展示白名单即由它派生，白名单之外的厂商（Google / 智谱 / Moonshot / 腾讯 / 其他）整体隐藏，不影响 `snapshot.all` 等权威数据。codexradar 的 `claude-*` 竞品条目不进 Codex 榜单，而是并入 Claude Code 分区（见下）。
- **「只看前沿」开关**：筛选行右端的橙色 chip（与分区筛选之间有竖线隔断——它管的是显示密度，不是第六个分区）。开启后隐藏被压制的行，选中态用橙色是因为它管的正是价格标橙的那批档位。判定始终基于**全量**组内数据：先过滤再判定会让基准漂移——压制者被隐藏后，被压制的行反而会翻身变成前沿。三类行不隐藏：未被压制的、缺花费或耗时因而没有判定的（价格中性灰，不算被压制）、以及推荐项与菜单栏当前档位——顶部场景推荐区固定展示后者，榜单里对应行消失会造成「上面推荐了、下面找不到」；这些豁免行改为淡化显示，表明它们本该被这个开关藏起来。组标题右侧标出隐藏条数（`IQ · 隐藏 6`）。名次配色沿用全量列表里的原始位次，切换开关不会让同一行改变颜色。每组至少留一行（组内最便宜的档位没有更便宜的能压制它，必为前沿），所以不会筛出空组。选择存入 `UserDefaults`，跨会话保持。
- **展示层瘦身**：榜单只对「看到什么」做三道收敛，`snapshot.all` / `codexGroup` 等权威数据与菜单栏选型都不受影响——① **质量过滤**：样本数 < 20 或 IQ < 50 的候选不展示，同一模型内 IQ 低于自身最高档 60% 的思考档也不展示（推荐项、菜单栏档位、`gpt-*` 一律豁免，避免误伤权威推荐与菜单栏一致性）；② **单档收敛**：`gpt-5.6-terra` 与 `gpt-5.6-luna` 候选档位多，各只展示一档（菜单栏档位优先，否则取 IQ 最高档）；③ **DeepSeek 限额**：该分组最多 3 条，推荐项优先保留。
- **稳定数据源 + 分层回退**：新主源不可用时回退 `current.json` 本地估算（UI 明确标注「本地估算」）；Claude 参考列尽力而为，抓不到也不影响 Codex。
- **轻量常驻**：无 Dock 图标，启动拉取 + 每 30 分钟轮询，`⌘R` 手动刷新、`⌘O` 打开网站。
- **纯只读、不上传**：只请求四个公开地址，不读取任何本机敏感数据。

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

应用在启动时拉取一次、之后每 30 分钟轮询一次，`⌘R` 可手动刷新。数据源按优先级分层：

两个权威源（radar-insights / intelligence-efficiency-metrics）瞬时失败会让整段榜单降级，因此失败后会短暂退避重试一次，两次都失败才按不可用处理。

- **站长推荐（权威源）**：`https://codexradar.com/api/radar-insights`，要求 `schema == 1`；`recommendations` 保持服务端数组顺序，每组含 `key`/`title`/`rule`/`items`，条目 identity 为 `model + effort`，字段含 `iq`/`passed`/`samples`/`average_cost_usd`/`average_duration_minutes`/`combined_cost_index`/`rule`/`trend_48h`。型号选择由它决定；菜单栏只接受 `daily_development` 中首个可匹配的 GPT 型号。
- **智力效率（权威指标源）**：`https://codexradar.com/api/intelligence-efficiency-metrics`，兼容 `schema == 2/3`；`points` identity 为 `model + effort`，字段含 `iq`/`passed`/`valid_tasks`/`average_price_usd`/`average_minutes`/`combined_cost_index`，顶层带 `source_updated_at`。Codex 列表的 IQ / 价格 / 时长 / 成本指数均取自此源。`combined_cost_index` 是成本指标（越低越省），**绝不用作能力排序**。
- **本地估算（完整失败回退）**：`https://codexradar.com/current.json` 的 `model_iq.latest` / `model_iq.comparisons`，仅当上述新主源不可用时才启用旧综合分公式，且 UI 明确标注「本地估算」；反之 `current.json` 失败不影响主数据。
- **Claude 评分（best-effort，参考）**：`https://claudecoderadar.com/data/claude-code-radar.json` 的 `iq.models[]`，各序列取最后一个非 null 值，组内按源 IQ 降序。**抓取或解析失败都不会影响 Codex**。
- **Claude Code 分区的两个源合并**：codexradar 的 `claude-*` 竞品条目会去掉 `claude-` 前缀（`claude-opus-5` → `opus-5`）并入 Claude Code 分区——它们此前既不进 Codex 榜单也不进 Claude 组，导致 codexradar 独有的 `opus-5` 完全看不到。**claudecoderadar 为主源**：同一 `模型名 + 档位` 两边都有时保留雷达数据（雷达样本 7~10 任务，竞品列常只有 1~5 任务），codexradar 只补雷达缺的档位；IQ 为 0 的档位与 `fable-*` 内部代号一律不展示。合并后按 IQ 降序、按合并后的 maxIq 重算进度条比例。两个源任务集不同、花费差一个量级（雷达 $10~127 vs 竞品列 $1.7~17），所以性价比橙/绿标记按 `metricSource` 分桶，**只在同源内比较**，不会出现「$1.7 的档位压制整批雷达条目」。两边都抓不到时 Claude Code 组才提示「数据提取失败」或隐藏。
- **检测时间戳**：优先取 insights / efficiency 的 `source_updated_at`，回退 `current.json` 的 `model_iq.quota_radar.updated_at`，再回退当前时间；按系统时区显示为 `YYYY-MM-DD HH:mm`，并实时展示「距今」。
- **日常开发补算**：当网页接口返回的 `daily_development.items` 为空时，使用同一响应的 `comprehensive_points` 与实时效率指标，筛选综合 IQ ≥ 90 的 GPT 档位，按平均耗时、综合成本指数、综合 IQ 排序，取前两项；因此菜单栏会推荐网站截图中的 `Sol medium`。
- **难题攻坚补算**：`hard_problems.items` 同样常年为空。按接口 `rule` 给出的规则复刻——有实测指标的 GPT 档位中按综合 IQ 从高到低取两项，IQ 相同再看模型顺序与综合成本；补算结果插在日常开发之后，保持服务端固有分组顺序。两组候选池互不排斥，同一档位可以同时带两个推荐标记。

> 主路径下 Codex 耗时来自 intelligence-efficiency 的 `average_minutes`；仅 `current.json` 本地回退时才采用其 `wall_seconds`（并发跑完的真实墙钟），与网页对比表的「总计算时长」口径不同。

### 部分成功降级规则

- insights + efficiency 都成功：efficiency 提供指标，insights 决定推荐分组与菜单栏（`daily_development` 首个可匹配 GPT 项）；榜单一律按 IQ 降序，推荐项不置顶——结论已由顶部场景推荐区承担，命中的行只带场景 chip。`combined_cost_index` 不参与能力排序。
- efficiency 失败（无论 insights 是否成功）：列表回退 `current.json` 本地估算的完整候选（UI 标注「本地估算」），站长推荐合并到匹配条目上（只写入场景 chip，不改变顺序）；推荐条目本身只有寥寥几条时不会把榜单塌缩成两三行。缺少效率指标时不进行日常开发补算。
- efficiency 与 `current.json` 都失败、只剩 insights：最后兜底，从推荐条目自身指标构建去重 Codex 列表（保持分组/条目首次出现顺序，合并推荐场景）。
- efficiency 成功、insights 失败：继续展示 efficiency 网站列表（按 IQ 降序）；菜单栏在 `current.json` 可用时按旧综合分得出的本地冠军 identity 匹配网站列表，不可用时回退网站列表第一项。本地公式不改变网站列表排序，也不标注为站长推荐。
- 三者都失败：抛错，头部展示错误提示。
- **不用更差的快照覆盖更好的**：`CodexDataSource` 三档按完整度排序（`website` > `localEstimate` > `recommendationsOnly`）。某次刷新只拿到更低一档时，`RadarViewModel` 保留上一次的好快照不覆盖，头部标出「未更新，展示上次结果」，上游恢复到同档或更高档才更新。这样一次瞬时故障不会把已经拿到的完整榜单换成两三条残缺列表。

## 本地估算综合分（仅回退时使用）

新主源不可用时才用旧公式作应急排序，四个维度几何加权（值越高越好），**按族各自归一化**——Codex 只和 Codex 比，Claude 只和 Claude 比：

```
maxIq   = 本族内最高 IQ
minCost = 本族内最小费用
minTime = 本族内最小耗时
score   = (iq / maxIq)         ^ 0.42
        × (min(passed,8) / 8)  ^ 0.13
        × (minCost / cost)     ^ 0.30
        × (minTime / time)     ^ 0.15
```

- 主路径（网站权威源）下进度条只是 IQ 视觉比例（`iq / 本组最高 IQ`），不展示任何自创总评分；上式综合分仅在「本地估算」标注下出现。
- 分 `Codex` / `Claude Code` 两组：回退路径下 Codex 按上式综合分降序（推荐项同样不置顶，只带场景 chip）；Claude Code 不走此公式，任何路径下都按源 IQ 降序。组内名次决定行配色（第 1 绿、第 2 黄、第 3 橙、第 4 名及以后红）。
- **两组不能横向比较**：Codex 来自 codexradar.com 权威数据，Claude 来自 claudecoderadar.com 参考快照，各自成榜、互不影响。

## 隐私

只请求 `https://codexradar.com/api/radar-insights`、`https://codexradar.com/api/intelligence-efficiency-metrics`、`https://codexradar.com/current.json` 与 `https://claudecoderadar.com/data/claude-code-radar.json` 四个公开地址，只读拉取、不提交任何数据。系统时区仅用于本地格式化更新时间，不上传时区、定位或其他设备信息；不读取通讯录、日历、定位、照片或麦克风等敏感数据。

## 工程结构

```
Sources/
├── App/        入口 + AppDelegate（状态栏 / 弹窗 / 轮询 / ⌘O·⌘R 快捷键）
├── Model/      领域模型 + 解析（RadarParser：insights / efficiency 主源 + 回退综合分）+ JSON 解码（CurrentResponse 等）
├── Service/    RadarService（insights + efficiency 主源，current.json 回退，claude-code-radar.json best-effort）
├── ViewModel/  RadarViewModel（快照 / 加载 / 错误 / 相对时间 / 「只看前沿」开关）
├── Views/      DesignTokens + 场景推荐区 + 分区筛选 + 榜单视图 + 头部 / 菜单栏 / 底部
└── Support/    VisualEffectView（深色毛玻璃）
Tests/
└── CodexRadarTests/  RadarParser / RadarService / RadarViewModel / StatusItemTitle 单元测试
```

## 免责声明

本项目为非官方客户端，不隶属于、也不代表 Codex 雷达网站、OpenAI、Anthropic 或其他第三方。网站名称、数据、商标和内容归各自权利人所有。

## 许可证

[MIT License](LICENSE)。MIT 只适用于本仓库代码，不授予任何第三方网站数据、品牌、商标、图标或内容的再授权。

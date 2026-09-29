# WakeLoop 产品设计与实施方案

> 版本：v1.0（2026-09-29，与用户两轮问答后定稿）
> 项目：d:\DevEco_studio\WakeLoop，HarmonyOS API 24（6.1.1），ArkTS 单 HAP、零三方依赖、纯本地无网络

---

## 1. 摘要

WakeLoop 是一个**多场景循环计时工具**：用户用"自由阶段序列"定义任何循环（番茄钟、BRAC 90/20、喝水提醒、久坐站立、小睡……），阶段内可选开启**随机唤醒**（随机间隔提示音 + 10 秒微休息，"Wake"的由来）。核心体验承诺：

1. **轻后台**：进程可被挂起，计时依然准确（墙钟时间戳驱动）；实况窗系统自刷新跳秒；边界提醒走系统代理（App 被杀也响）。
2. **实况窗刚需**：当前阶段倒计时上实况窗（胶囊 + 卡片）。用户配合走 AGC 权益流程；权益下来前自动降级为常驻通知 + 代理提醒。
3. **扩展四件套**：统计报表、提示音库、桌面卡片、健康复盘（分期）。

**两个关键纠错（相对旧项目 FocusApp 的结论）**：
- 旧项目"后台长时任务被平台拒绝（9800005）"实为 **module.json5 漏配 `backgroundModes: ["audioPlayback"]`**（已核对旧项目配置属实，官方错误码文档明确此因）。本方案轻后台不需要长时任务，但此纠错为远期"后台随机唤醒"升级留了通路。
- 实况窗**个人不上架可用**：AGC 申请"实况窗服务权益"（约 5 个工作日）→ 把自己手机加入"调测设备管理"名单（按 Push Token，最多 100 台，名单内设备不做权限校验）。只有"正式权限"才要求上架 + 月活 ≥ 1000。

## 2. 现状与可复用资产

### 2.1 新项目脚手架（已就绪）
- `build-profile.json5`：targetSdkVersion 6.1.1(24)，debug 签名已配置（default_WakeLoop）
- `AppScope/app.json5`：bundleName = `com.example.wakeloop`（**待改，见 §8 决策 D1**）
- entry 模板：EntryAbility + Index（Hello World 原样）

### 2.2 旧项目可复用资产（d:\DevEco_studio\Focuds\FocusApp）
| 资产 | 位置 | 复用方式 |
| --- | --- | --- |
| 14 种提示音源 | `entry/src/main/resources/rawfile/sounds/` | 直接拷入新项目 rawfile |
| AVPlayer 状态驱动链 | 旧 SoundManager 实现 + AGENTS.md 踩坑 #16/#17 | 按状态机模式重写（initialized→prepare→play→completed→release，每音独立实例） |
| 实况窗参数经验 | 旧 LiveViewController + 踩坑 #18 | PICKUP 模板 + ${placeholder.timer} + countdownPreset；clickAction 必须 WantAgent；不写 WantAgent 类型注解 |
| UI 基线 | 上传的《鸿蒙App开发指南.md》 | 拷入新项目 docs/ 作为唯一 UI 规范 |
| 踩坑清单 | 旧 AGENTS.md §6 踩坑 #1-19 | 全部继承，择要写入新 AGENTS.md |
| 需求依据 | 上传的《鸿蒙专注App调查报告.md》 | 拷入新项目 docs/（BRAC/随机唤醒方法论、健康复盘远期依据） |

### 2.3 平台硬约束（调查结论，2026-08/09 官方文档）
- 实况窗：须 AGC 权益；单个实况窗生命周期 **≤ 8 小时**；本地创建依赖应用进程，创建后倒计时由系统自刷新；模拟器不支持（真机 MIS-AL00 验证）
- 调测设备：按 Push Token 添加，24h 内生效，权限有效期与 Push Token 一致（需定期续期）
- reminderAgentManager：系统代理提醒，App 被杀也能触发；模拟器无法验证，真机可用（需 PUBLISH_AGENT_REMINDER 权限 + 通知授权）
- ArkTS 卡片：TextTimer（API 10+）支持卡片内倒计时显示；卡片刷新有配额，倒计时交给 TextTimer 自渲染

## 3. 产品设计

### 3.1 概念模型（核心数据结构）

```
Scene 场景 = {
  id, name, colorToken,        // 场景名 + 主题色（用于环形/卡片/实况窗图标底色）
  phases: Phase[],             // 有序阶段列表（≥1）
  loopCount: number,           // 循环轮数：0=无限，N=固定轮数
  source: 'template' | 'custom'
}
Phase 阶段 = {
  name,                        // 如"专注""休息""喝水"
  durationMs,                  // 时长
  endSound,                    // 阶段结束音（音库 id，可为'无'）
  wakeEnabled,                 // 本阶段是否开启随机唤醒
  wakeMinMs / wakeMaxMs,       // 随机间隔区间（默认 3-5 分钟）
  microBreakMs                 // 微休息时长（默认 10s，0=不做微休息）
}
```

**内置模板**（首批，均由上述模型派生，用户可另存为自定义）：
番茄钟（25 专注[随机唤醒]/5 休息 ×4）、BRAC（90[随机唤醒]/20）、喝水提醒（60min 单阶段无限循环）、久坐站立（45 坐/5 站）、小睡（20min 单阶段）、学习循环（50/10 ×3）。

**全局约束**：同一时刻只允许一个运行中场景（实况窗只支持一个；心智简单）。

### 3.2 运行时状态机（LoopEngine）

```
idle ──start(scene)──▶ running
running: phase(i, cycle j)
  ├─ wakeEnabled && 到达 nextWakeAt ──▶ 播放唤醒音 ──▶ microBreak(倒计时) ──▶ 回到 running
  ├─ 到达 phaseEndAt ──▶ 播放 endSound ──▶ 下一阶段/下一轮 ──▶ running 或 completed
  ├─ pause ──▶ paused（记录 pausedAt，恢复时重排）
  └─ stop/reset ──▶ idle（写会话记录）
completed：循环轮数耗尽 ──▶ 播放场景结束音 ──▶ idle（写会话记录）
```

**时间正确性（轻后台核心）**：所有时刻只存"锚点"：`sceneStartAt / phaseStartAt / pausedAccum / nextWakeAt / phaseEndAt`（绝对墙钟时间戳），落盘到 Preferences 快照。回前台/App 重启时 `recompute()`：用当前系统时间与锚点差值推算当前阶段/轮次/进度，**跳过挂起期间已结束的阶段**（边界音不补播，只补状态）。暂停期间不推进。随机唤醒的排程用**相对增量**（nextWake = now + rand(min,max)），继承旧项目踩坑 #12 教训。

### 3.3 页面结构（Navigation + Tabs）

| 页面 | 内容 |
| --- | --- |
| 主页-运行 | 场景名 + 阶段名、圆形进度环 + 中央倒计时、轮次指示（第 N/M 轮或 ∞）、阶段序列分段条（每阶段一色段）、暂停/跳过阶段/结束按钮、微休息遮罩（全屏橙色环 + 10s 倒计时，可设置关闭） |
| 主页-场景库 | "我的场景"卡片列表 + 模板卡片 + 新建入口；卡片点击即启动 |
| 场景编辑 | 名称/主题色/循环轮数（含无限）；阶段列表（增删改排序）；阶段展开高级项：结束音、随机唤醒开关 + 区间 + 微休息时长 |
| 统计页 | 周期切换（今日/本周/本月/本年）：总时长、完成轮数、完成率、中断率；柱状图（周期联动，复用旧项目横滑/缩放方案）；按场景分解列表 |
| 设置页 | 音量、默认随机唤醒区间、微休息遮罩开关、实况窗开关 + 权益状态展示、数据保留与清理、深浅色说明（跟随系统） |

UI 硬基线（继承《鸿蒙App开发指南.md》全文）：沉浸式 + 安全区避让（PageTitleBar 公共组件，chevron_left 返回）、深浅色全 `$r()` + dark/ 覆盖零硬编码、Navigation 路由表、列表 LazyForEach + 业务 id key、Toast/弹窗/空态统一封装。

### 3.4 轻后台分层策略

| 层 | 机制 | 进程要求 |
| --- | --- | --- |
| 计时准确 | 墙钟锚点 + 回前台重算（§3.2） | 无（挂起/被杀均可恢复） |
| 实况窗 | TIMER 计时场景（PICKUP 布局 + ${placeholder.timer} + countdownPreset），系统自刷新跳秒；阶段切换时若进程活着则 updateLiveView | 创建/更新需进程；跳秒不需要 |
| 边界提醒 | reminderAgentManager 代理提醒：每个阶段结束时刻预约一条（Calendar 型绝对时间）；提醒文本含场景/阶段/下一阶段名；点击提醒拉起应用并恢复状态 | 无（系统代理触发） |
| 降级通知 | 无实况窗权益时：常驻通知（进度文本，阶段切换时更新）+ 代理提醒 | 更新需进程存活，被杀后通知保留最后状态 |
| 随机唤醒 | **仅前台有效**（轻后台决策的自然结果）；挂起期间不响不补，恢复后基于墙钟重排下一次 | 前台 |

**8 小时实况窗生命周期对策**：无限循环场景（如喝水提醒）运行超 8h 实况窗会被系统收尾。策略：代理提醒响铃时用户点进 App（Want 拉起），进程恢复后重建实况窗；不做后台自动重建。文案上把"实况窗"定位为前 8 小时的增强显示。

### 3.5 扩展功能
- **统计报表**：sessions 表 SQL 聚合（时长/完成轮数/中断率/按场景分解），柱状图复用旧项目方案（显式总宽 + 横滑 + 双指缩放）
- **提示音库**：rawfile 14 音源 + 每阶段独立结束音 + 4 组事件音（唤醒/微休开始/微休结束/场景完成，各含"无"）+ 试听
- **桌面卡片**：2×2 ArkTS 卡片：当前运行状态（场景/阶段 + TextTimer 倒计时）+ 2 个常用场景快启按钮（message 事件 router 拉起）；未运行时显示快启
- **健康复盘（P3 远期）**：Health Service Kit 读手环 9 心率/HRV/压力，统计页按会话时段叠加（依据旧调查报告 §3；需 AGC 申请 10-15 工作日，与开发并行）

## 4. 数据与存储

- **RelationalStore（SQLite）**，两张表：
  - `scene`：id, name, colorToken, loopCount, phasesJson, source, sortOrder, createdAt, updatedAt
  - `session`：id, sceneId, sceneNameSnapshot, startedAt, endedAt, status(completed/stopped/paused-abandoned), completedCycles, detailJson（各阶段实际时长）
- **Preferences**：设置项 + 运行态快照（锚点时间戳，见 §3.2）
- schema 版本号 + 升级开关预留（user_version）
- 会话数据保留 6 个月自动清理（旧项目 3 个月，调整为可配置）

## 5. 代码结构

```
entry/src/main/ets/
├── common/        # 常量、类型定义（Scene/Phase/Session）、时间工具
├── engine/        # LoopEngine 状态机、RandomWakeScheduler、SnapshotStore
├── data/          # SceneRepository、SessionRepository（RelationalStore）
├── services/      # SoundService（AVPlayer 状态链）、LiveViewService、
│                  # ReminderService（代理提醒）、NotifierService（降级常驻通知）、
│                  # StatsService（聚合查询）
├── pages/         # Home（运行+场景库 Tabs）、SceneEdit、Stats、Settings
├── components/    # PageTitleBar、PhaseRing、PhaseStrip、SceneCard、MicroBreakOverlay
└── widget/        # 桌面卡片（FormExtensionAbility + WidgetCard）
docs/              # AGENTS.md（根目录）、鸿蒙App开发指南.md、调查报告.md
```

## 6. 实施路线（每期独立可验证、可回滚、git 提交）

| 期 | 内容 | 验证标准 |
| --- | --- | --- |
| **M0 基线** | bundleName 定稿改名；拷贝 docs + 建新 AGENTS.md（含踩坑继承）；UI 骨架（沉浸式/深浅色资源/Navigation/PageTitleBar）；构建链路跑通（hvigorw assembleHap + hdc 安装） | 模拟器冒烟：空壳四页导航正常，深浅色切换无白底 |
| **M1 计时内核** | Scene/Phase 类型 + 内置模板 + LoopEngine + SnapshotStore（锚点重算）+ RandomWakeScheduler；**本地单测全覆盖**（含：挂起重算/跨阶段跳过/暂停恢复/无限循环/随机唤醒相对排程） | 单测全绿；缩短时长的模拟器冒烟一轮完整循环 |
| **M2 场景与主页** | 场景库页（模板卡片 + 我的场景 + RelationalStore CRUD）、场景编辑页（阶段编辑/排序/高级项）、主页运行视图（圆环/分段条/轮次） | 模拟器：创建自定义场景→启动→暂停/跳过/结束正常；重启 App 状态恢复 |
| **M3 声音系统** | SoundService（AVPlayer 状态驱动链，hilog 全链路）+ 音库选音试听 + 随机唤醒 + 微休息遮罩端到端 | 模拟器：唤醒音 3-5min 触发→微休息→恢复（复用旧项目验证脚本思路）；试听按钮即点即响 |
| **M4 边界提醒** | ReminderService（阶段结束代理提醒，Calendar 绝对时间；启动时清理旧提醒只保留下一个边界）+ 降级常驻通知 | **真机**：锁屏/杀 App 后阶段到点提醒可达，点提醒拉起恢复状态 |
| **M5 实况窗** | LiveViewService（PICKUP + timer placeholder + countdownPreset + clickAction WantAgent；含 §2.2 踩坑 #18 全部要点）+ 权益状态探测与降级开关 | 权益下来前：模拟器跑通降级路径不报错；**权益后真机**：胶囊/卡片/锁屏出现且跳秒，阶段切换更新 |
| **M6 统计** | sessions 聚合 + 统计页四周期 + 柱状图 + 按场景分解 | 单测（聚合纯函数）+ 模拟器对拍手造数据 |
| **M7 桌面卡片** | 2×2 卡片（TextTimer 倒计时 + 快启按钮） | 真机：卡片倒计时跳秒、快启拉起、运行态同步 |
| **M8 健康复盘（P3）** | Health Service Kit 接入 + 会话时段心率叠加 | 依赖 AGC 审核通过，单独 PoC |

构建/测试命令（沿用旧项目经验）：
```
d:\DevEco_studio\DevEco Studio\tools\hvigor\bin\hvigorw.bat assembleHap --mode module -p product=default   # 或项目内 .\hvigorw.bat
hdc install entry\build\default\outputs\default\entry-default-signed.hap
hdc shell aa start -a EntryAbility -b <bundleName>
单测：hvigorw test --mode module -p module=entry@default -p coverage=false -p unittestType=local
```

## 7. AGC 行动清单（用户操作，与 M2-M5 并行）

1. **定 bundleName**（见 D1），AGC → 开发与服务 → 创建项目 + 应用（包名一致）
2. 我在 M5 前产出《实况窗场景方案设计》（场景描述/展示时机/节点，可用官方可视化工具排版后截图）
3. AGC → 项目设置 → 开放能力管理 → 实况窗服务 → 提交申请（**约 5 个工作日**）
4. 通过后：App 内临时接入 `pushService.getToken()`（仅用于设备注册，不引入其他推送依赖），把 MIS-AL00 加入 调测设备管理（24h 生效）
5. （远期可选）Health Service Kit 权益申请（M8 前）

## 8. 假设与决策

| # | 决策 | 理由 |
| --- | --- | --- |
| D1 | **bundleName 从 `com.example.wakeloop` 改为正式名**（建议 `com.wakeloop.app`，AGC 注册时确认唯一性；你也可指定其他） | 要走 AGC 实况窗权益，com.example.* 在 AGC 注册应用受限；现在改成本≈0，之后改要动签名/数据 |
| D2 | 全局单运行场景 | 实况窗单实例；多并行循环复杂度不成比例 |
| D3 | 随机唤醒仅前台；后台随机唤醒（音频长时任务保活）列为**远期可选升级**（backgroundModes 配置方案已在手，随时可加） | 你选择轻后台；且 9800005 真因已查明，未来升级无平台阻塞 |
| D4 | 挂起期间错过的边界音不补播，状态照常推进 | 补播多段音频无意义且打扰；代理提醒已覆盖到点触达 |
| D5 | 提醒只预约"下一个阶段边界"，触发/拉起后再约下一个 | 避免长场景积压大量代理提醒 |
| D6 | 统计口径：暂停时长不计入有效专注；手动结束记 partial | 继承旧项目最终口径 |
| D7 | 本方案不引入 Push/网络功能，Push Token 仅设备注册用（M5 后可留可撤） | 纯本地原则 |

## 9. 验证与收尾纪律（继承用户工作流）

- 每期完成即 git 提交（做了什么 + 踩了什么坑），当场更新 AGENTS.md
- 同一构建命令最多重试 3 次，失败先自查（ArkTS 红线：禁 any/delete/解构，对象字面量显式类型，正则 new RegExp()）
- 单元测试优先于 UI 模拟器操作；UI 只做里程碑冒烟；真机断开重连一次失败即切模拟器继续
- 实况窗/代理提醒必须真机验证，模拟器结论不作为"失败"依据（旧踩坑 #19）

## 10. 风险登记

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 实况窗权益申请被拒（材料不合格） | M5 真机验证延后 | 按官方模板写场景方案 + 可视化工具截图；降级路径已内置，不阻塞其他期 |
| 调测设备 Push Token 过期 | 实况窗突然失效 | 设置页展示权益/调测状态；文档记录重新 getToken + 重新添加流程 |
| 实况窗 8h 生命周期 | 无限循环场景显示中断 | §3.4 对策；文案定位为增强显示 |
| reminderAgent 真机行为差异（提醒样式/拉起） | M4 验证反复 | 真机 PoC 放最前；旧项目已确认 API 用法正确 |
| ArkTS 语法/组件坑 | 各期 | 继承旧项目 19 条踩坑 + 开发指南红线，全部写入新 AGENTS.md |

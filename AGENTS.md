# AGENTS.md —— WakeLoop Agent 开发指南

## 1. 这是什么项目

鸿蒙多场景循环计时工具（个人自用，不上架）。核心概念：**场景 = 自由阶段序列 × 循环轮数**（番茄钟/BRAC/喝水/站立等模板均由它派生），阶段内可开启**随机唤醒**（随机间隔提示音 + 10 秒微休息）。

- 架构决策：ArkTS/ArkUI 单 HAP、零三方依赖、纯本地无网络（AVPlayer 音频、RelationalStore 数据、Preferences 设置与运行态快照、reminderAgentManager 边界提醒、实况窗 TIMER 场景）
- **轻后台**：不申请长时任务。计时准确性靠墙钟锚点 + 回前台重算；实况窗倒计时系统自刷新；边界提醒走系统代理（App 被杀也响）
- 实况窗依赖 AGC"实况窗服务权益"+ 调测设备名单（个人不上架路径，详见 docs/方案 §2.3、§7）
- 远期：Health Service Kit 心率复盘（docs/鸿蒙专注App调查报告.md）
- 完整设计方案：`.trae/documents/WakeLoop-产品设计与实施方案.md`（唯一事实来源）

## 2. 接手流程（新会话必做，按顺序）

1. 读本文档 + 方案文档
2. `git log --oneline -10` 确认进度
3. `hdc list targets` 确认设备（真机 MIS-AL00；实况窗/代理提醒仅真机可验证）

## 3. 开发方法论

新增功能模块：定契约（数据模型/接口签名）→ 实现 → 单元测试（`entry/src/test/`）→ 构建验证 → 冒烟 → 更新本文档 §6 → git 提交。

## 4. 硬约束（违反会浪费大量时间）

- bundleName：`com.wakeloop.app`（改名后需在 DevEco 重新自动签名一次）
- 构建命令（最多重试 3 次，失败先自查）：
  ```
  .\hvigorw.bat assembleHap --mode module -p product=default
  ```
  若项目内无 wrapper：`d:\DevEco_studio\DevEco Studio\tools\hvigor\bin\hvigorw.bat assembleHap --mode module -p product=default`
- 安装：`hdc install entry\build\default\outputs\default\entry-default-signed.hap`
- 启动：`hdc shell aa start -a EntryAbility -b com.wakeloop.app`
- 日志：`hdc hilog | findstr WakeLoop`
- 单测：`hvigorw test --mode module -p module=entry@default -p coverage=false -p unittestType=local`；结果在 `entry/.test/default/intermediates/test/coverage_data/coverage.log` grep "Tests run"
- UI 一致性规范遵循 `docs/鸿蒙App开发指南.md`（沉浸式+安全区、深浅色 $r() 资源零硬编码、统一返回图标 sys.symbol.chevron_left、Navigation 路由、List 用 LazyForEach + 业务 id 做 key）
- ArkTS 语法红线：禁 any/unknown、禁 delete、禁解构、对象字面量需显式类型、正则用 new RegExp()、String.replace 不支持回调、async 必须显式返回类型
- 定时器/事件监听必须在 aboutToDisappear 清除；Promise 必须 catch；回调用箭头函数
- 单元测试优先于 UI 模拟器操作；UI 只做里程碑冒烟
- 实况窗/代理提醒：模拟器不支持，模拟器结论不作为失败依据；真机断开重连一次失败即切模拟器

## 5. 关键技术决策（踩过坑换来的，勿推翻）

1. **随机唤醒排程必须相对增量**：nextWake = now + rand(min,max)，不是从起点累计（旧项目踩坑 #12：绝对位置排程导致微休息连续触发）
2. **AVPlayer 必须状态驱动链**：createAVPlayer → on('stateChange') → initialized 时 prepare → prepared 时 setVolume+play → completed 时 release；设 fdSrc 后不同步调 prepare（旧项目踩坑 #16/#17：prepare 竞态 5400102，"提示音从来没响过"的真因）；每个短音独立实例
3. **实况窗**（旧项目踩坑 #18，参数已全部过校验）：primary.clickAction 必填（WantAgent）；计时类用 LAYOUT_TYPE_PICKUP 模板 + ${placeholder.timer} + countdownPreset（PROGRESS 模板必须 nodeIcons）；wantAgent 结果不写类型注解
4. **沉浸式下 NavDestination 系统 TitleBar 不避让状态栏**：统一 hideTitleBar(true) + 公共组件 PageTitleBar（chevron_left + topAvoidPx 避让）
5. **旧项目后台 9800005 的真因**是 module.json5 漏配 backgroundModes（非平台封锁）；本项目轻后台不申请长时任务，若未来做后台随机唤醒，补 `backgroundModes: ["audioPlayback"]` + AVSession
6. resourceManager.getRawFd() 返回 Promise；preferences 用 getPreferencesSync
7. 模拟器：长时任务、实况窗、代理提醒均不可验证
8. uitest dump 的 bounds 按 JSON 字母序在 text 之前，解析要向前找最近 bounds
9. 本地单测无真实文件系统（fileIo 报 libuv -4058），文件 IO 测试放 ohosTest
10. ArkTS 组件字段禁命名 background/opacity/width 等保留属性名

## 6. 当前状态与下一步

- ✅ 2026-09-29 M0-1：bundleName 改为 com.wakeloop.app（AGC 实况窗权益前置要求）；⚠️ 签名 profile 仍绑旧包名，需在 DevEco → File → Project Structure → Signing Configs 重新自动签名一次
- ✅ 2026-09-29 M0-2：docs/ 拷入《鸿蒙App开发指南.md》《鸿蒙专注App调查报告.md》；建立本 AGENTS.md
- ✅ 2026-09-29 M0-3：UI 骨架完成——EntryAbility 沉浸式（异步 then 链 + 安全区高度入 AppStorage + 深浅色状态栏图标）、Navigation + 路由表四页（Home 双 Tab / SceneEdit / Stats / Settings，占位）、公共 PageTitleBar（chevron_left 48vp 热区）、深浅色全资源色板（phase_0-5 阶段色 + micro_break）
- ✅ 2026-09-29 M0-4：CompileArkTS + PackageHap 全过；**SignHap 失败（预期内）**：debug profile 绑定旧包名 com.example.wakeloop，hvigor 校验 bundleName 不匹配即拒签。⚠️ 待用户在 DevEco → File → Project Structure → Signing Configs 点 Fix 重新自动签名（唯一阻塞项，不影响 M1 单测/编译验证）
- ⬜ M1-M8：见方案文档 §6 实施路线

## 7. 文档维护纪律（必须遵守）

- 每解决一个 bug/踩一个坑/做一个架构决策，**当场**更新本文档
- 每完成一个可验证的功能就 git 提交，commit message 写清"做了什么 + 踩了什么坑"
- 收尾动作固定：清理测试数据 → 更新 §6 进度 → git 提交
- 发现文档过时立即修，以代码为准

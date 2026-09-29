# 鸿蒙 App 开发指南 —— UI 适配与常见坑（个人参考手册）

> 用途：开发新鸿蒙 App 时的默认基线与踩坑速查。
> 来源：ArkSilly 项目实战沉淀（方案均已真机/模拟器验证）+ 官方文档与社区资料。
> 最后更新：2026-09-07

---

## 0. 个人开发基线（新 App 默认按此配置）

| 项 | 默认方案 |
| --- | --- |
| 导航/工具控件 | **悬浮式**（Stack 子组件 + 绝对 position 定位，不占布局空间） |
| 顶部/底部安全区 | **沉浸式扩展**：`setWindowLayoutFullScreen(true)`，内容绘制到状态栏/导航条后面，自身用安全区高度避让 |
| 状态栏/小横条 | 不遮挡画面内容；状态栏图标颜色随主题动态切换（深色主题白图标、浅色主题黑图标） |
| 键盘避让 | 压缩式（聊天 App 式：顶栏不动、内容区压缩、输入框贴键盘上方），严禁系统级+组件级双重避让 |
| 深浅色 | 资源限定词 `dark/` 目录 + `$r()` 引用自动切换，不缓存颜色值；**每个新页面/弹窗必须同时适配深浅色** |
| 横竖屏 | `orientation: "auto_rotation_restricted"`（尊重系统旋转锁），旋转事件 600ms 防抖 |
| 返回按钮 | 统一用系统图标（详见 §6.1），禁止"返回"文字按钮与图标按钮混用 |
| 安全区策略 | 全应用统一（要扩全扩、要避全避），策略写进 AGENTS.md，禁止各页面自行发挥 |

---

## 1. 沉浸式与安全区适配

### 1.1 开启沉浸式（内容延伸到状态栏/导航条下）

```ts
// EntryAbility.ets → onWindowStageCreate
// 深色窗口背景：消除启动白屏闪烁
windowStage.getMainWindowSync().setWindowBackgroundColor('#121212');

// 沉浸式布局。注意：必须走异步 then 链，窗口未就绪时同步调用会静默失败
windowStage.getMainWindow().then((mainWindow: window.Window) => {
  mainWindow.setWindowLayoutFullScreen(true).then(() => {
    const barProps: window.SystemBarProperties = { statusBarContentColor: '#ffffff' };
    return mainWindow.setWindowSystemBarProperties(barProps);
  });
});
```

**坑：全屏布局 API 同步调用静默失败。** `getMainWindowSync()` 拿到窗口后立刻调 `setWindowLayoutFullScreen` 可能不生效也无报错，用 `getMainWindow().then(...)` 异步链最稳。

### 1.2 原生页面避让状态栏/导航条

沉浸式开启后，内容会顶到系统栏下面，需要自己避让：

```ts
// 获取避让区高度（物理像素，用 px2vp 换算）
const win = windowStage.getMainWindowSync();
const topAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
const bottomAvoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
```

两种处理方式：

- **不沉浸的内容区**：`padding({ top: px2vp(topAvoid.topRect.height), bottom: px2vp(bottomAvoid.bottomRect.height) })`
- **背景沉浸、内容避让**：根容器加 `.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])` 让背景延伸绘制，内部内容仍留在安全区

### 1.3 WebView 页面避让（ArkWeb）

Web 页面用 CSS `env()` 处理（前端需带 `viewport-fit=cover`，注入时机在 `onPageEnd`）：

```ts
// 注入安全区 CSS：顶栏/输入栏避让状态栏与导航条，横屏还要避让左右挖孔
const css = ':root{'
  + '--topBarBlockSize:calc(var(--topBarIconSize) + var(--topBarBlockPadding) + env(safe-area-inset-top));'
  + '--bottomFormBlockSize:calc(var(--bottomFormIconSize) + var(--bottomFormBlockPadding) + env(safe-area-inset-bottom));'
  + '}'
  + '#top-bar{padding-top:env(safe-area-inset-top) !important;}'
  + '#form_sheld{padding-bottom:env(safe-area-inset-bottom) !important;}'
  + '#sheld{padding-left:max(env(safe-area-inset-left),2px) !important;'
  + 'padding-right:max(env(safe-area-inset-right),2px) !important;}';
```

### 1.4 状态栏图标颜色随主题切换

```ts
private syncStatusBarColor(): void {
  const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  window.getLastWindow(context).then((win: window.Window) => {
    const props: window.SystemBarProperties = {
      statusBarContentColor: this.isDarkMode ? '#ffffff' : '#000000' // 深色主题白图标
    };
    win.setWindowSystemBarProperties(props);
  });
}
```

---

## 2. 悬浮控件与边界处理（越界问题重点）

### 2.1 为什么悬浮控件经常"飞出屏幕"

根因有三个，全部与 ArkUI 的坐标/布局语义有关：

1. **`offset({x,y})` 只是视觉偏移，不提供任何边界约束**，且是"相对自身原始位置"的偏移，不是相对屏幕左上角的坐标系。在 `onActionUpdate` 里累加 `dx/dy`，可以向 ±∞ 任意跑。
2. **容器对齐方式改变坐标原点**。`Stack({ alignContent: Alignment.End })` 或 overlay 的 align 会先把组件"原始位置"推走，你以为原点在左上角，实际累加偏移是在被推过的位置上算的——不做钳制，出界是几何必然。
   - 实测案例（ArkSilly 缩放控件）：overlay + Alignment.End 实际渲染到了顶部居中，与钳制逻辑假设的基准位不一致，导致控件只能停在左上象限。
3. **屏幕尺寸单位混用**。`display.getDefaultDisplaySync().width/height` 返回的是**物理像素**，手势 `offsetX/Y` 是 **vp**，直接比较必然越界。必须除以 `densityPixels` 换算。

### 2.2 推荐方案：绝对 position + 屏幕尺寸钳制

```ts
// 状态直接定义为"控件左上角相对父容器左上角"的绝对坐标
@State ctlX: number = 180;
@State ctlY: number = 400;

// 屏幕物理像素 → vp
private clampCtlPos(): void {
  const d = display.getDefaultDisplaySync();
  const density = d.densityPixels > 0 ? d.densityPixels : 3;
  const vpW = d.width / density;
  const vpH = d.height / density;
  const ctlW = 46;  // 控件宽 + 余量
  const ctlH = 110; // 控件高 + 余量
  if (this.ctlX < 4) { this.ctlX = 4; }
  if (this.ctlY < 4) { this.ctlY = 4; }
  if (this.ctlX > vpW - ctlW - 4) { this.ctlX = vpW - ctlW - 4; }
  if (this.ctlY > vpH - ctlH - 4) { this.ctlY = vpH - ctlH - 4; }
}
```

```ts
// 悬浮控件本体：Stack 子组件，绝对 position 定位
// 长按 400ms 进入拖动模式（半透明反馈），松手钳回屏幕内
@Builder
private floatControls() {
  Column({ space: 6 }) {
    // ... 按钮/内容
  }
  .position({ x: this.ctlX, y: this.ctlY })
  .opacity(this.dragging ? 0.55 : 1.0)
  .gesture(
    GestureGroup(GestureMode.Sequence,
      LongPressGesture({ repeat: false, duration: 400 })
        .onAction(() => { this.dragging = true; })
        .onActionEnd(() => { this.dragging = false; }),
      PanGesture()
        .onActionStart(() => {
          this.dragStartX = this.ctlX; // 记录本次拖动起点，offset 是相对手势起点的增量
          this.dragStartY = this.ctlY;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.ctlX = this.dragStartX + e.offsetX; // 拖动中不钳制，跟手优先
          this.ctlY = this.dragStartY + e.offsetY;
        })
        .onActionEnd(() => {
          this.dragging = false;
          this.clampCtlPos(); // 松手才钳制
        })
        .onActionCancel(() => {
          this.dragging = false;
          this.clampCtlPos();
        })
    )
  )
}
```

要点清单：

- ✅ 用 `position({x, y})`（相对父容器左上角，语义直接），不用 `offset` 累加
- ✅ 拖动中记录 `dragStartX/Y`，用 `手势起点位置 + e.offsetX/Y` 更新，避免 offset 语义误解
- ✅ 屏幕尺寸必须 `物理像素 / densityPixels` 换算成 vp
- ✅ 松手/取消时钳制；**旋转、折叠屏展开后也要重新钳制**（见 §2.4）
- ✅ 若需要吸附边缘动画：`animateTo({ curve: curves.responsiveSpringMotion() }, ...)` 弹性跟手

### 2.3 悬浮容器不能挡住下层触摸

**坑：全屏悬浮容器即使设置 `HitTestMode.None`，其内部空白区域仍会拦截触摸事件**，导致网页/下层内容无法点击。

解决：悬浮控件**只占自身大小**（不用全屏容器包一层），用 Stack 子组件 + 绝对 position 直接定位。控件区域外天然不拦截。

### 2.4 旋转/折叠屏后位置失效

屏幕尺寸变化后，之前钳制过的坐标可能又越界。监听 display 变化并重新钳制（带防抖）：

```ts
aboutToAppear(): void {
  display.on('change', (_id: number) => { this.onDisplayChange(); });
}
private onDisplayChange(): void {
  // 600ms 防抖：旋转过程中的中间态（尺寸半变）会误触发
  if (this.rotationTimer !== -1) { clearTimeout(this.rotationTimer); }
  this.rotationTimer = setTimeout(() => {
    this.rotationTimer = -1;
    this.clampCtlPos(); // 尺寸变了，重新钳回屏幕内
  }, 600);
}
aboutToDisappear(): void {
  display.off('change'); // 必须解绑，否则泄漏
}
```

### 2.5 子窗口悬浮窗（createSubWindow，跨页面悬浮）

应用内悬浮优先用 Stack 方案；需要跨页面/独立窗口时用 `createSubWindow`：

- 子窗口拖动：PanGesture + `window.moveTo`；**若调用了 `setFollowParentWindowLayoutEnabled(true)`，moveTo/resize 将不生效**（布局被锁定跟随主窗口）
- 透明背景 `setWindowBackgroundColor` + `setWindowTouchable(false)` 防止阻挡主窗口手势

---

## 3. 键盘避让（画面被顶出屏幕问题）

### 3.1 机制：两层独立避让，同时启用必然双重顶起

鸿蒙的键盘避让有**两层互相独立的机制**：

| 层级 | API | 行为 |
| --- | --- | --- |
| 系统级 | `UIContext.setKeyboardAvoidMode()` | OFFSET（整个窗口上推，**默认**）/ RESIZE（压缩窗口高度）/ NONE |
| 组件级 | Web 的 `.keyboardAvoidMode()` / 滚动容器自动滚焦 | 组件内部自行避让 |

**典型翻车现场**：系统级默认 OFFSET 推整个窗口，Web/组件内部又避让一次，双重叠加 → 画面被顶出屏幕顶部（底部输入框场景 100% 复现）。

### 3.2 WebView 场景（ArkSilly 验证方案）

```ts
// EntryAbility.ets：关闭系统级避让（必须在 loadContent 之后，UIContext 就绪）
windowStage.loadContent('pages/Index', () => {
  windowStage.getMainWindowSync().getUIContext()
    .setKeyboardAvoidMode(KeyboardAvoidMode.NONE); // 关掉系统级 OFFSET！
});

// Index.ets：避让完全交给 Web 组件，用压缩模式
Web({ src: this.serverUrl, controller: this.controller })
  .keyboardAvoidMode(WebKeyboardAvoidMode.RESIZE_CONTENT)
```

- `RESIZE_CONTENT`：聊天 App 式——顶栏不动、内容区压缩、输入框贴键盘上方（前端 viewport meta 带 `interactive-widget=resizes-content` 时为 W3C 官方预期行为）
- `RESIZE_VISUAL`：浏览器式整页滚动避让，顶栏会被滚出屏幕（用户反馈不接受）

### 3.3 原生页面场景

- **表单/登录页**：`Scroll`/`List` 滚动容器 + 内容撑出可滚动高度，系统自动把焦点输入框滚入可视区
- **坑：`Column + height('100%') + layoutWeight` 锁死高度，RESIZE 模式下纹丝不动**——系统只缩画布不挪组件，固定布局必被键盘遮挡。弹性布局（layoutWeight/百分比）才会随 RESIZE 压缩
- **自定义底部输入栏**（系统自动避让覆盖不了）：手动监听键盘高度

```ts
const win = await window.getLastWindow(this.getUIContext().getHostContext() as common.UIAbilityContext);
win.on('keyboardHeightChange', (height: number) => {
  this.keyboardHeight = px2vp(height); // 底部栏 translate/padding 该高度
});
// aboutToDisappear 里必须 off，否则泄漏
```

- 自定义键盘：`customKeyboard(builder, { supportAvoidance: true })` 才参与避让，默认 false

---

## 4. 状态刷新与图片缓存（改了不刷新问题）

### 4.1 @State 观察不到的变更

ArkUI 只观察**第一层**赋值：

```ts
// ❌ 深层属性改动不刷新
this.dataList[0].name = 'new';

// ✅ 方案一：整体替换引用
this.dataList = [...newData];

// ✅ 方案二：嵌套类用 @Observed + @ObjectLink
@Observed class UserModel { name: string = ''; }
@Component struct UserItem {
  @ObjectLink user: UserModel; // 深层变化立刻刷新
}
```

排查思路（官方五步）：状态变量是否收集到依赖（build 中被"读"过）→ 赋值前后值是否真的变化（相同值直接跳过）→ 赋值是否可观察 → 数据源与同步对象是否有关联（@Link/@Prop）→ 组件更新函数是否执行。工具：DevEco 的 ArkUI Inspector。

### 4.2 图片同路径覆盖后不刷新（头像框不刷新的根因）

**Image 组件按 `src` 做缓存键**。编辑图片后在**同一路径**写入了新内容（如头像文件覆盖保存），`src` 字符串没变 → 框架判定无变化 → 继续用缓存的旧纹理。典型场景：编辑头像 → 预览不刷新。

```ts
// ✅ 方案一（推荐）：路径加时间戳破缓存
this.avatarUrl = `${path}?t=${Date.now()}`;

// ✅ 方案二：key 强制销毁重建组件
Image(this.imgSrc).key(`img-${Date.now()}`)

// ✅ 方案三：文件内容哈希做查询参数（内容没变时不闪重载）
```

### 4.3 Image 官方已知行为

- `src` 由**有效值切无效值**（加载失败路径/空值）时，组件**保持显示旧图不清除**（官方行为，非 bug）。API 22+ 用 `alt` 属性设占位图；低版本在 `onError` 回调里手动把 `src` 换成占位图资源
- 网络图加载中/失败要有占位：`alt($r('app.media.placeholder'))` + `.onError(...)`

---

## 5. 深色/浅色模式切换不刷新问题

### 5.1 正确姿势：资源限定词，代码零判断

```
resources/
├── base/element/color.json      # 浅色（兜底）
│   { "color": [{ "name": "page_bg", "value": "#F1F3F5" }] }
└── dark/element/color.json      # 深色（只覆盖需要变的）
    { "color": [{ "name": "page_bg", "value": "#1A1A2E" }] }
```

```ts
// 代码里一律 $r() 引用，系统切 colorMode 时自动重新匹配资源，无需监听
Column().backgroundColor($r('app.color.page_bg'))
```

### 5.2 "退出 app 才刷新"的常见根因

| 根因 | 修复 |
| --- | --- |
| 颜色**写死**在代码里（`'#FFFFFF'`）而非 `$r()` 资源 | 全部改 `$r()` + dark/ 目录覆盖 |
| 在 `aboutToAppear` 把 `$r()` 结果**缓存进变量**，切模式不重取 | 每次 build 实时 `$r()`，不缓存 |
| 属性里用**函数返回值**判断深浅色（如 `backgroundColor(this.getBg())`） | 高性能模式下切换深浅色**不会全量重跑属性代码**，此写法失效；改状态变量绑定 |
| 用了 `setColorMode()` 手动锁定后，期望 `onConfigurationUpdate` 回调 | **主动 setColorMode 不触发 onConfigurationUpdate**（官方明确），自己刷新 UI |
| 应用内三档开关（浅/深/跟随系统）重启丢设置 | `setColorMode` 不持久化，用 Preferences 存，启动时读回并重新 setColorMode |

### 5.3 需要感知模式变化的场景（资源覆盖不到的）

```ts
// 方案一：页面内 mediaquery 监听（ArkSilly 在用）
const mq = this.getUIContext().getMediaQuery();
this.darkListener = mq.matchMediaSync('(prefers-color-scheme: dark)');
this.isDarkMode = this.darkListener.matches;
this.darkListener.on('change', (result: mediaquery.MediaQueryResult) => {
  this.isDarkMode = result.matches; // @State 驱动弹窗配色、状态栏图标颜色等
});
// aboutToDisappear 必须 off('change')

// 方案二：Ability 级 onConfigurationUpdate + AppStorage
onConfigurationUpdate(newConfig: Configuration): void {
  AppStorage.setOrCreate('currentColorMode', newConfig.colorMode);
}
// 页面里 @StorageProp('currentColorMode') @Watch('onModeChange') mode: number
```

### 5.4 应用内模式控制与持久化

```ts
// 三档：COLOR_MODE_NOT_SET(-1 跟随系统) / COLOR_MODE_LIGHT(0) / COLOR_MODE_DARK(1)
// 只能通过 ApplicationContext（UIAbilityContext/UIContext 没有此方法）
this.getUIContext().getHostContext()?.getApplicationContext()
  .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);

// 持久化：preferences 存字符串，EntryAbility.onWindowStageCreate 读回再 setColorMode
```

---

## 6. UI 交互一致性规范（多 Agent 协作必读）

> 背景：不同 agent（甚至同一个 agent 的不同会话）设计页面时，交互细节极易发散——
> 返回按钮有的用图标有的用汉字、有的页面扩展安全区有的不扩、弹窗配色有的适配主题有的白底黑字。
> 一致性必须在项目层面用**规范 + 公共资源 + AGENTS.md 约束**三件套锁死，不能指望每个会话自觉。

### 6.1 返回按钮统一

- 左上角返回**一律用系统图标**（HarmonyOS SymbolGlyph 或 sys 资源），全应用一个样式：

```ts
// 推荐：SymbolGlyph 系统符号（跟随系统风格）
SymbolGlyph($r('sys.symbol.chevron_left'))
  .fontSize(24)
  .fontColor([$r('app.color.icon_primary')])

// 备选：sys 图标资源
Image($r('sys.media.chevron_left'))
  .fillColor($r('app.color.icon_primary'))
```

- **禁止**"返回"文字按钮与图标按钮混用；禁止自绘箭头（不同 agent 画的箭头粗细圆角必不一致）
- 用 `Navigation` 组件时系统返回箭头自动处理，优先用 Navigation 而不是自拼顶栏
- 交互行为也要统一：返回 = 关闭当前浮层/页面，不掺业务动作；系统侧滑返回与左上角按钮行为必须一致（都走 `onBackPress` 同一套分层逻辑，见 §6.3）

### 6.2 安全区策略统一

- 项目开工时就定好全应用唯一策略（推荐沉浸式扩展，见 §0 基线），**写进 AGENTS.md 硬约束**
- 封装统一的页面骨架（如 `BasePage` 组件：统一处理沉浸式 padding、顶栏、背景色），agent 写新页面必须继承骨架，禁止从零自拼
- 判别标准要写清："内容可滚动区域背景延伸到系统栏下（expandSafeArea），可交互控件（按钮/输入框）全部留在安全区内"——不给 agent 自由裁量空间

### 6.3 交互模式统一清单

| 交互 | 统一约定 |
| --- | --- |
| 返回 | 图标统一（§6.1）；行为统一：浮层→历史→退出确认分层 |
| 退出确认弹窗 | 一个应用一份样式，配色跟随主题，禁止白底黑字写死 |
| Toast 提示 | 统一封装 `showToast(message)`，时长/位置全应用一致 |
| 加载态 | 统一 LoadingProgress 样式 + 文案格式，禁止各页面自造转圈 |
| 空态/错误态 | 统一占位组件（图标 + 文案 + 重试按钮） |
| 确认对话框 | 统一用系统 `AlertDialog` 或同一个自定义组件，按钮顺序/颜色统一 |
| 触摸反馈 | 统一一个 `clickEffect`/透明度反馈方案 |

### 6.4 主题适配自查清单（提交前必过）

新页面/新弹窗开发完，agent 必须逐项自查：

- [ ] 所有颜色来自 `$r('app.color.*')` 且 `dark/` 目录有对应覆盖，**零硬编码色值**（`#FFFFFF` 直接打回）
- [ ] 弹窗/卡片背景绑定主题状态变量，深浅两种模式截图/预览各验一次
- [ ] 状态栏图标颜色与新页面主题匹配（深色页白图标）
- [ ] 图片资源如需深浅两版，放 `base/` + `dark/` 同名
- [ ] 用系统侧滑返回 + 深浅色切换实测一遍页面，无白底黑字、无颜色缓存残留

### 6.5 公共资源先行

- 颜色/字号/圆角/间距全部定义在 `resources/base(element)` + `dark/`，页面只引用不定义
- 通用组件（顶栏、返回按钮、弹窗、Toast、空态）在开发第二批页面前就要沉淀出来——第一批页面写完，把可复用部分抽成公共组件，写进 AGENTS.md 让后续会话直接复用

---

## 7. 项目文档与 AGENTS.md 规范（Agent 工作流）

> 参考 ArkSilly 项目实践：AGENTS.md + START_HERE.md + 踩坑记录 + sessions 交接 + git 提交纪律，
> 这是多会话/多 agent 开发不崩盘的关键。**新项目第一件事就是建这套文档，而不是先写代码。**

### 7.1 新项目必建文档（按优先级）

| 文档 | 作用 | 要点 |
| --- | --- | --- |
| **AGENTS.md**（根目录） | 任何 agent/开发者接手前必读的**唯一入口** | 见下方模板 |
| **START_HERE.md**（或并入 AGENTS.md） | 一页式当前进度 + 下一步 | 每完成一个阶段必须更新，过期信息直接删 |
| **踩坑记录**（HANDOFF.md 或 AGENTS.md 内章节） | 坑点 + 根因 + 解法 | 解决问题的当场就写，不许"以后补" |
| **docs/sessions/**（可选） | 会话中断交接 | 上传中断时写明：做到哪、卡在哪、下一步 |

### 7.2 AGENTS.md 模板

```markdown
# AGENTS.md —— <项目名> Agent 开发指南

## 1. 这是什么项目
一句话说明 + 架构决策（如：前端方案、后端方案、数据模型）

## 2. 接手流程（新会话必做，按顺序）
1. 读本文档
2. 读进度清单/START_HERE 确认当前阶段
3. `git log --oneline -5` 确认进度；确认模拟器/设备在线

## 3. 开发方法论
如何新增一个功能模块：定契约 → 实现 → 测试 → 收尾

## 4. 硬约束（违反会浪费大量时间）
- 构建命令、部署命令、测试策略
- UI 一致性规范（引用本文档 §6：返回图标、安全区策略、主题自查清单）
- ArkTS 语法红线

## 5. 快速命令速查
构建/部署/日志/调试命令，直接可复制执行

## 6. 当前状态与下一步
✅ 已完成 / 🚧 进行中 / 🧊 冻结，附 commit hash

## 7. 文档维护纪律（必须遵守）
- **每次解决新问题/踩新坑，必须当场更新本文档或踩坑记录**
- 每阶段结束：更新进度 → git 提交（坑点写进 commit message）
- 会话中断：写 docs/sessions/ 交接文件
- **禁止文档与现实脱节**：发现文档过时，先改文档再写代码
```

### 7.3 文档纪律硬约束（写给 agent 的规则）

1. **时刻保持文档最新**：每解决一个 bug、每踩一个坑、每做一个架构决策，**当场**写进文档。不许"任务结束后统一补"——会话结束后记忆就没了。
2. **git 提交跟随里程碑**：每完成一个可验证的功能/修复就提交，commit message 写清"做了什么 + 踩了什么坑"（参考 `git log` 历史格式），方便以后考古。
3. **收尾动作固定**：清理测试数据 → 更新进度文档 → git 提交。三步缺一不可。
4. **接手先读文档**：新会话第一动作是读 AGENTS.md 和最新进度，禁止凭记忆/直觉直接改代码。
5. **发现文档过时立即修**：以代码为准，文档错了改文档，而不是将错就错。

---

## 8. 其他高频坑速查

### 8.1 module.json5

```json5
"orientation": "auto_rotation_restricted" // 尊重系统旋转锁定开关；不要写死 landscape/portrait
```

### 8.2 ArkWeb 显示优化（真机实测）

```ts
Web({ src: url, controller: controller })
  .overScrollMode(OverScrollMode.NEVER)     // 去掉过滚动回弹（手感像卡顿）
  .verticalScrollBarAccess(false)           // 触屏场景隐藏滚动条
  .horizontalScrollBarAccess(false)
  .fileAccess(false)                        // 不用的权限全关，减少内核开销
  .databaseAccess(false)
```

- `controller.zoom()` 实测无效；控制视口宽度只能改 viewport meta 的 `width=N`
- CDP 调试：`webview.WebviewController.setWebDebuggingAccess(true)` 必须在 Web 初始化前（放 aboutToAppear）

### 8.3 返回键分层（用户体验基线）

`onBackPress` 优先级：**关闭前端浮层（弹窗→对话框→抽屉，一层层退）→ 历史回退 → 退出确认**。退出确认弹窗配色跟随应用主题，避免固定白底黑字。

### 8.4 ArkTS 语法红线

- 禁 `any/unknown`；`Array.isArray` 收窄后需 `as Object[]` 再迭代
- 禁 `delete` 运算符；禁解构；对象字面量需显式类型（空对象用 `emptyRecord()` helper）
- `String.replace` 不支持回调函数，需 `RegExp.exec` 循环
- 深层嵌套对象字面量逐层声明中间变量，内联 `as` 断言不足
- 正则用 `new RegExp()` 不用字面量

### 8.5 列表渲染与性能（来源：社区高频踩坑 + 官方最佳实践）

**① ForEach 全量渲染，大列表必掉帧**
`ForEach` 一次性构建全部子组件（200 条实测 20fps、内存 320MB）。数据量 > 20 条的列表**必须用 `LazyForEach`**（只渲染可视区，实测回到 60fps）：

```ts
// LazyForEach 数据源必须实现 IDataSource 接口
class NewsDataSource implements IDataSource {
  private data: NewsItem[] = [];
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.data.length; }
  getData(index: number): NewsItem { return this.data[index]; }
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter(l => l !== listener);
  }
  addItem(item: NewsItem): void {
    this.data.push(item);
    this.listeners.forEach(l => l.onDataAdd(this.data.length - 1)); // 增量通知
  }
}
```

**② keyGenerator 用 index 当 key → 滑动闪烁/数据错乱（List 闪烁 99% 根因）**

```ts
// ❌ 绝对禁止：index 做 key，数据增删/排序变化后错乱
LazyForEach(this.data, gen, (item: X, index: number) => index.toString())
// ✅ 必须用业务唯一 id
LazyForEach(this.data, gen, (item: X) => item.id)
```

**③ LazyForEach 数据源修改后必须发通知**
直接 `push`/修改数据源数组 UI 不动——它和 @State 是两套机制，必须调 `onDataReloaded()`/`onDataAdd()`/`onDataChange()` 等 listener 方法。

**④ 组件复用必须在 aboutToReuse 里重置状态**
滑出屏幕的节点进复用池，滑入时直接复用（不重走 itemGenerator）。不重置视觉状态 → 快速滑动闪现旧数据（图片最明显）：

```ts
@Component struct NewsCard {
  @ObjectLink item: NewsItem;
  @State imageLoaded: boolean = false;
  aboutToReuse(params: Record<string, Object>): void {
    this.imageLoaded = false; // 复位图片加载标志、动画状态等
    this.item = params['item'] as NewsItem;
  }
}
```

**⑤ 懒加载失效的隐蔽场景**
`Scroll` 嵌套 `List`（外层可滚动时 List 会全量加载）、`GridItem` 不设固定高度——都会让按需加载失效退化成全量。

### 8.6 生命周期与异步

- **异步完成时组件已销毁仍更新 @State → 崩溃**：耗时请求回来前用户可能已退出页面，需存活标志位防护（aboutToDisappear 置 false，回调里先检查）
- **build() 里禁止调异步函数**：渲染期触发状态更新会导致渲染异常，异步逻辑放 aboutToAppear/事件回调
- **`onPageShow`/`onPageHide` 在 Navigation 模式下不触发**：用 NavDestination 的 `onShown`/`onHidden` 替代
- **Promise 未 catch 直接 Crash**：所有 `.then()` 必须配 `.catch()`，async 函数用 try-catch 包裹
- **回调里 `this` 为 undefined**：一律用箭头函数 `() => this.method()`
- **定时器/事件监听必须清除**：`setTimeout`/`setInterval`/`display.on`/`window.on` 等在 aboutToDisappear 里统一 off/clear，否则泄漏（本指南 §2.4 已示范）

### 8.7 网络请求与持久化

- **http 必须设超时**：`connectTimeout`/`readTimeout` 不设会永久挂起；推荐 10s/30s
- **明文 HTTP 默认被禁**：http:// 请求需在 module.json5 配置 network 相关 cleartext 选项，优先用 https
- **后端 Long 型 ID 超 16 位丢精度**：雪花算法 ID 经 `JSON.parse` 变成错误数字（浮点截断），后端返回 String 或用 bigint 处理
- **并发请求要限流**：无上限并发会 OOM，用队列/信号量控制并发数
- **Preferences 同步 API（getSync/putSync）勿在主线程频繁调用**：阻塞 UI 线程可致 ANR，大批量操作用异步接口或 TaskPool
- **RelationalStore 的 ResultSet 用完必须 close**：不关闭会耗尽连接池，后续查询全部失败

### 8.8 状态管理 V2、布局细节与路由

**状态管理 V2（@ComponentV2 体系）**
- `@ObservedV2` 类的属性**必须加 `@Trace`** 才可观察，忘加 → 更新静默失效（无报错）
- V2 数组重赋值偶发不触发刷新 → `[...arr]` 展开强制换引用 + 立即本地 filter
- `AppStorage` 存复杂对象会**丢失方法**（只序列化数据），存 id/原始类型，对象重建

**布局细节**
- `Text` 不设 width/flexShrink(1) 会无限撑开父容器，省略号失效
- `z-index` 只在同一父容器内生效，跨容器调层级要改组件树结构
- `Scroll` 嵌套 `List` 双向滑动冲突，二选一

**路由：统一用 Navigation，弃用 router**
- `router.pushUrl` 已 deprecated；统一 `Navigation` + `NavPathStack.pushPathByName`，全部路由集中在一个 PageMap 路由表注册（参数强类型，不满天飞 `Record<string, any>`）
- **跨页面状态同步**：详情页改了数据，返回首页要刷新——用 NavDestination 的 `onShown` 回调 + 版本号/回调通知，别指望页面自动重渲染

---

## 9. 参考链接

- 安全区域/expandSafeArea/setKeyboardAvoidMode（官方）：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-universal-attributes-expand-safe-area
- 软键盘遮挡 FAQ（官方）：https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-1118
- 状态变量不刷新定位方法（官方）：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/troubleshooting-state-manage
- Image 组件参考（官方）：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-image
- Image 占位图 FAQ（官方）：https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-arkui-847
- 深色模式适配及持久化 FAQ（官方）：https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-arkui-1266
- 子窗口无法拖动 FAQ（官方）：https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-arkui-1165
- 悬浮窗拖拽和吸附动画（官方示例）：https://blog.csdn.net/liuhaojiabin/article/details/145231178
- 键盘避让踩坑指南（社区）：https://harmonyosdev.csdn.net/6a94ebfe3bda720d4b382d7e.html
- 深色模式 ResourceManager 机制（社区）：https://harmonyosdev.csdn.net/6a968b0e2b83d06f0eca8481.html
- 深浅色适配指南（官方）：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/ui-dark-light-color-adaptation-V5
- 懒加载优化性能最佳实践（官方）：https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-lazyforeach-optimization
- LazyForEach 键值与数据刷新异常 FAQ（官方）：https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-arkui-828
- 鸿蒙开发实战：100 个项目疑难杂症汇编：https://blog.csdn.net/weixin_46476460/article/details/157654153
- 鸿蒙开发避坑日记：30 个真实 bug：https://harmonyosdev.csdn.net/6a05900c54b52172bc7430f2.html
- LazyForEach 复用逻辑与旧数据闪现：https://juejin.cn/post/7656077196734775322
- 列表性能实战 ForEach→LazyForEach：https://ost.51cto.com/posts/54884
- Navigation 路由架构与跨页状态同步：https://developer.huawei.com/consumer/cn/blog/topic/03214316681684006

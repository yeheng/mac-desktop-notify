# Vue 3 动画库选型调研：为「多种自定义动画」选型

> 日期：2026-10 · 对象：`tauri-nc-replica/`（Tauri 2 + Vite + Vue 3 `<script setup>` + TS + shadcn-vue + Tailwind v4）
> 运行宿主：macOS WKWebView（WebKit），目标平台 macOS 26（Safari 26 引擎）
> 本报告只做研究与结论，不含任何代码改动。

---

## 0. 摘要（TL;DR）

- **继续 motion-v，不换库、不引入第二套 JS 动画引擎。** motion-v 是唯一一个能同时覆盖全部六类需求（入/退场多变体、layout/FLIP 重排、手势、微动效、可复用 spring 预设、stagger）的库，且与现有 `swiftSpring(response, dampingFraction)` 换算同构，维护方就是 Framer Motion 团队（Motion division）。
- **现状发现：motion-v 目前是「已声明但未使用」的死依赖**——`src/` 没有任何 `import "motion-v"`，全部动画靠 `src/lib/motion.ts` 手写 CSS transition + `ToastStack.vue`/`ToastCard.vue` 里的 pointer 数学完成。所以「继续 motion-v」实质是「真正开始用 motion-v」，而不是「守住现状」。
- **组合策略：motion-v（domMax，惰性加载）作为唯一 JS 动画引擎 + CSS 承担两类廉价动画**（展开/收起高度用 grid `0fr→1fr` 技巧、循环脉动/进度用 `@keyframes` / `tw-animate-css`），不引入 GSAP / anime.js / @vueuse/motion / auto-animate。
- **硬约束命中**：GSAP 因「Standard no-charge license」（非 OSI 开源）被排除；@vueuse/motion 因已停更 ~19 个月被排除；@motionone/dom 已归档（被 Motion 取代）；anime.js v4 无 layout/gesture 被排除；auto-animate 只做 FLIP 重排、无 spring/gesture，仅可作为辅助选项（结论：不需要）；View Transitions API 无 spring 物理、无手势，只适合页面级转场，不适合本栈。

---

## 1. 需求矩阵与评估维度

### 1.1 六类动画需求 → 能力映射

| # | 需求 | 所需能力 | 关键约束 |
|---|------|---------|---------|
| A | 卡片入/退场：slide / fade / scale / spring 多变体（对应 Swift `ToastMotion` 的 `transition` 词汇） | 挂载/卸载编排 + tween/spring + 可变体 | 必须与 Swift `ToastStyle.swift` 的 5 档 + 不对称 insertion/removal 语义一致 |
| B | 层叠 pile/deck 重排：layout animation（位移，非淡入淡出） | FLIP / projection layout | 每帧 `getBoundingClientRect` 已用于原生材质同步（`useFrameReporter`），layout 动画必须仍能让 rect 反映真实变换 |
| C | 展开/收起：高度补间（CSS grid `0fr→1fr`） | 纯 CSS，不需 JS 引擎 | 越便宜越好 |
| D | 手势：拖拽跟手、惯性滑走、短拖弹回 | pointer 跟踪 + velocity + spring 收尾 | 必须精确还原 Swift `dismissDrag`（90pt 线性 / 90pt 后 0.5 阻力 / `predictedEndTranslation` 220pt 判决） |
| E | 微动效：进度胶囊、计数器、循环脉动 | 轻量 tween / CSS keyframes | 零 JS 或极低 JS 成本 |
| F | 可复用 spring 预设：对齐 Swift `response/dampingFraction` | spring 引擎参数同构 + 预设注册表 | `swiftSpring()` 已存在（stiffness=ω², damping=2ζω, mass=1），须作为唯一换算源 |

### 1.2 硬约束

1. Tauri WebView（macOS WKWebView / WebKit）——WAAPI、`ResizeObserver`、`IntersectionObserver`、`Element.animate` 均可用，但需注意 Safari 对 `composite`/部分 WAAPI 特性的历史差异。
2. Vue 3 `<script setup>` + TS——需要一等公民 Vue 集成或可干净手动接线。
3. 可摇树（sideEffects:false + ESM）。
4. 维护活跃、宽松许可证（MIT/Apache/BSD；GSAP 的「no-charge」非宽松）。

---

## 2. 对比总表

| 维度 | **motion-v**（Motion for Vue） | @vueuse/motion | GSAP 3 | anime.js 4 | @formkit/auto-animate | @motionone/dom | View Transitions API |
|---|---|---|---|---|---|---|---|
| 版本（调研时） | 2.8.0（项目锁 ^2.7.0） | 3.0.3 | 3.15.0 | 4.5.0 | 0.10.0 | 10.18.0 | 原生，Safari 18+ |
| 许可证 | **MIT** | MIT | ❌ Standard no-charge（非 OSI） | MIT | MIT | MIT | 原生 |
| 维护 | ✅ 极活跃（Framer Motion 团队） | ⚠️ 停更 ~19 个月（2025-03） | ✅ 活跃（商业背书） | ✅ 活跃（v4 重写） | ✅ 活跃 | ❌ 已归档（2024-11） | 浏览器演进中 |
| GitHub stars / open issues | 2.2k / 7 | 2.8k / 50 | 29k / 7 | 74k / 124 | 14k / 47 | 2.9k / 66（归档） | — |
| 动画模型 | tween + spring + keyframes + timeline + **gesture** + **layout(FLIP)** | tween + spring（popmotion） | tween + timeline + keyframes + scroll/drag(插件) + Flip | tween + timeline + stagger + spring(v4) | **仅 layout(FLIP)** | tween + spring + keyframes + timeline | 仅快照交叉淡化 + CSS |
| 自定义/预设 | variants + `createPresetDirective` + 自定义预设指令 | 内置 fade/pop/roll/slide 变体 | 函数式，任意编排 | 函数式 | 无（单行） | 函数式 | 无 |
| 多段序列编排 | ✅ `animate()` 数组 / timeline | ❌ | ✅ timeline（最强） | ✅ timeline | ❌ | ✅ timeline | ❌ |
| stagger 交错 | ✅ `stagger()` + `delay` | ⚠️ 仅 `:delay` 道具 | ✅ 最强 | ✅ 最强 | ❌ | ✅ | ❌ |
| Vue Transition/TransitionGroup 集成 | ✅ 组件 `<Motion>`/`v-motion` + `AnimatePresence` + `usePresence` | ✅ `v-motion` + `<Motion>`/`<MotionGroup>` + `MotionPlugin` | ❌ 手动 ref + `gsap.context` 生命周期清理 | ❌ 手动 | ✅ `v-auto-animate` + `useAutoAnimate` | ❌ 手动 | 手动 `startViewTransition` 包状态更新 |
| 生命周期/退场 | `AnimatePresence`（含 popLayout） | leave 变体（配合 Transition） | 手动 | 手动 | 自动 | 手动 | 原生 |
| 手势拖拽 | ✅ `drag`/`useDragControls`/`useMotionValue`/`useVelocity` | ❌ | ⚠️ Draggable 插件（部分收费） | ❌ | ❌ | ❌ | ❌ |
| spring 参数同构 | ✅ `{type:'spring',stiffness,damping,mass}` | ✅ 同构（popmotion） | ⚠️ 不同物理模型（需再拟合） | ⚠️ v4 spring 为缓动曲线，非物理 | ❌ | ✅ `{stiffness,damping,mass}` | ❌ |
| WebKit 兼容 | WAAPI 为主，Safari 13.1+ | rAF JS 循环 | rAF JS 循环（最稳） | rAF JS 循环 | rAF FLIP | WAAPI | Safari 18+ |
| gzip 体积（min / gzip） | 按需：`m` 5KB / `domAnimation` 25.7KB / `domMax` 39.6KB（gzip） | 36.6KB / 13.7KB | 69KB / 26.7KB（core） | 114KB / 39.3KB | 8.1KB / 3.2KB | 22.3KB / 9.2KB | **0** |
| 摇树 | ✅ sideEffects:false, ESM | ✅ | ✅（ESM） | ⚠️ v4 摇树一般（sideEffects 含 adapters） | ✅ | ✅ | — |
| 结论 | ✅ **采用** | ❌ 停更 | ❌ 许可证 | ❌ 缺 layout/gesture | 可选辅助 | ❌ 归档 | ❌ 缺物理/手势 |

---

## 3. 逐库详评

### 3.1 motion-v（Motion for Vue）—— ✅ 采用

**身份澄清（重要）**：motion-v **不是** Motion One 的轻量封装，而是 **Motion（framer-motion 14 的继任者）的官方 Vue 移植**。其 `package.json` 直接依赖 `framer-motion ~14.1.0` + `motion-dom` + `motion-utils` + `hey-listen`。因此评估体积时要以 framer-motion 14 的引擎为准，而不是「motion-v 自己那 4KB 的 index」。

**动画模型**：全谱系。tween（WAAPI 驱动）、spring（物理弹簧）、keyframes、timeline/sequence（`animate()` 传数组）、gesture（`drag`/`whileHover`/`whileTap`/`whileDrag`/`press`/`inView`）、layout（FLIP projection，`LayoutGroup` + `layout` prop）、stagger（`stagger()` + `delayInMs`）。

**自定义能力**：
- 变体（variants）：`initial`/`animate`/`exit` 三态 + 命名变体对象，支持 `custom` 传参动态选变体。
- 预设指令：`createPresetDirective()` 可把「命名动画」打包成自定义 Vue 指令（如 `v-preset-slide`），正是「多种自定义动画预设」的落点。
- 命令式：`useAnimate()` 返回 `[scopeRef, animate]`，`animate()` 支持序列数组与 stagger，可完全脱离模板在 `onEnter`/`onLeave` 钩子里用——与当前 `ToastStack.vue` 的 `:css="false"` 钩子式接线天然吻合。
- 低阶值：`useMotionValue` / `useSpring` / `useVelocity` / `useTransform` / `useAnimationFrame`，是手势跟手 + 惯性滑走 + 短拖弹回的正确工具箱。

**Vue 集成**：`MotionPlugin`（全局）；组件 `<Motion>`（别名 `<m>` / `<M>`）、`<AnimatePresence>`（退场编排，支持 `mode="popLayout"` 让离开元素脱离文档流、其余元素自动 layout 归位——正是 pile 里删卡后 deck 重排想要的）、`<LayoutGroup>`、`<Reorder.Group>`（拖拽重排列表）；指令 `v-motion` / `v-preset`；hook `usePresence()`（感知自己是否在退场中，用于与 Vue 原生 `<Transition>` 协调）。既可用 AnimatePresence 完全接管，也可继续用 Vue `<TransitionGroup :css="false">` 并在钩子里 `animate()`。

**WebKit 兼容性陷阱**：
- 底层 `m`（WAAPI 基座）需要 Safari 13.1+；macOS 26 的 WKWebView 无压力。
- spring 无法直接交给 WAAPI（WAAPI 无物理弹簧），Motion 会把 spring **采样成关键帧序列**再喂给 `Element.animate()`；重度欠阻尼（bounce 的 dampingFraction 0.68）需要足够采样点，否则高频末端有可见量化——对本项目两档（0.86/0.68）可控。
- `composite: "add"`（多轴叠加）在较旧 Safari 有缺陷，Motion 有降级路径；macOS 26 已无此问题。
- **与 `useFrameReporter` 的配合（本项目关键）**：`getBoundingClientRect()` 返回的是**渲染后**的矩形，WAAPI 动画驱动的 transform 也会反映进去，因此原生材质面（material.rs）每帧仍能拿到动画中的真实位置——不需要改上报逻辑。但注意：WAAPI 动画不在 inline style 上，`readFrames` 靠 `getComputedStyle`/rect 读，仍然正确；只是会比读 inline style 略贵（每帧强制布局），卡片数量少（<10）可接受。
- `AnimatePresence` 的退场依赖 `usePresence`，需要 Vue 的 unmount 时机配合；在 `:css="false"` 的 TransitionGroup 内混用时要避免「Vue 等 done、motion 也在等」的双时钟——建议二者取其一（见 §5 接线建议）。

**体积与摇树**（实测 framer-motion 14.1 的 `size-rollup-*.js`）：
| 入口 | 说明 | min | gzip |
|---|---|---|---|
| `m` | WAAPI 基座（只读关键帧） | 12.5 KB | 5.0 KB |
| `domAnimation` | `m` + animate/spring/sequence | 75.0 KB | 25.7 KB |
| `domMax` | `domAnimation` + drag + layout projection + Reorder | 124.3 KB | 39.6 KB |
| `animate`（仅命令式） | 无组件层 | 53.3 KB | 18.9 KB |
| `scroll` | 滚动驱动 | 8.9 KB | 3.8 KB |

本项目需要 gesture + layout，故目标是 **`domMax`（~39.6KB gzip，摇树后）**；若后续证明 layout 用 CSS `transition` 已够（deck 重排其实可用 `transition: transform` 实现，见 §5），可降级到 `domAnimation`（25.7KB gzip）。两者都是 `LazyMotion` 可再懒拆（`features` 显式声明，只加载 drag/layout 所需 feature），进一步压缩。

**维护**：`motiondivision/motion-vue`，MIT，2219 stars，最近 push 与发布均在 2026-10（调研当日），7 个 open issue 且响应快。这是 7 个候选中**唯一同时满足「Vue 一等公民 + 全能力 + MIT + 活跃」**的。

### 3.2 @vueuse/motion —— ❌ 停更排除

- 引擎：popmotion + framesync + style-value-types + defu + @vueuse/core。
- 模型：tween + spring（`{type:'spring', stiffness, damping, mass}`，与 motion-v **同构**，也能映射 SwiftUI spring）；变体词汇 `initial`/`enter`/`visible`/`visibleOnce`/`leave`，内置 `fade/pop/roll*/slide*` 预设。
- 集成：`v-motion` 指令、`<Motion>`/`<MotionGroup>` 组件、`MotionPlugin`；`useMotion`/`useSpring`/`useMotionVariants`/`useReducedMotion`。
- 短板：**无 layout/FLIP、无手势、无 timeline 序列、无真 stagger**（只有 `:delay` 道具逐项手工错开）、退场靠 Vue Transition 的 leave 变体（无 AnimatePresence 的 popLayout）。
- 体积：36.6KB min / 13.7KB gzip。
- 维护：`vueuse/motion` 最后发布 2025-03-10，仓库最后 push 2025-03-11——**已停更约 19 个月**，50 个 open issue 无人收。Vue 3.5/3.6 新版本下无兼容承诺。**直接排除。**

### 3.3 GSAP 3 —— ❌ 许可证排除（能力上其实最强）

- 模型：tween + timeline（业界最强编排）+ keyframes + stagger + morph；`Flip` 插件做 layout、`Draggable` 做手势、`ScrollTrigger` 做滚动。
- Vue 集成：无官方 Vue 3 wrapper，需手动 `ref` + `onMounted` 建 `gsap.context()`、`onBeforeUnmount` 调 `ctx.revert()` 清理。可行但样板多、与 `<TransitionGroup>` 编排需自己桥。
- WebKit：rAF JS 循环，不依赖 WAAPI，兼容性最好。
- 体积：core 69KB min / 26.7KB gzip；拖拽/Flip 插件另计。
- **许可证是硬伤**：`Standard 'no charge' license`（https://gsap.com/standard-license）。对绝大多数 App 免费，但**不是 OSI 开源**，且部分插件（SplitText、MorphSVG、部分 Draggable 高级能力）要付费。与「宽松许可证」硬约束冲突。**排除。**

### 3.4 anime.js 4 —— ❌ 缺 layout/gesture

- 模型：tween + timeline + keyframes + stagger（内置极强）；v4 新增 spring 缓动（但 spring 是缓动曲线拟合，非物理弹簧，无法精确对齐 `response/dampingFraction`）。
- Vue 集成：框架无关，手动 `ref` + 生命周期清理。
- 体积：114KB min / 39.3KB gzip（v4 相比 v3 的 ~7KB gzip 大幅膨胀，摇树一般）。
- 维护：活跃（v4 重写，2026-06 发布），MIT，74k stars。
- 短板：**无 layout/FLIP、无手势拖拽系统**；spring 非物理模型，无法承接需求 F。**排除**（作时间轴库很强，但本栈不需要第二套引擎）。

### 3.5 @formkit/auto-animate —— 可选辅助，结论不需要

- 模型：**只做 FLIP layout 重排**（子元素增删/移动自动补间），一行接入。
- Vue 集成：`v-auto-animate` 指令 + `useAutoAnimate()`，一等公民。
- 体积：8.1KB min / 3.2KB gzip。
- 短板：**无 spring/tween 精细控制、无手势、无 stagger、无序列**；只有几个 easing 选项。
- 定位：它和 motion-v 的 layout 能力重叠，且 motion-v 更强（有 spring layout transition + popLayout）。**本栈不需要它**；若未来某个列表只想要「零配置重排」，可零成本补，但会引入第二套 FLIP 实现，不划算。

### 3.6 @motionone/dom —— ❌ 已归档

- 模型：tween + spring + keyframes + timeline + stagger，WAAPI 驱动，纯命令式。
- 体积：22.3KB min / 9.2KB gzip，很轻。
- 维护：`motiondivision/motionone` **2024-11 归档**，官方明确由 Motion（framer-motion 14 / `motion` 包）继承。而 motion-v **正是** Motion 的 Vue 端口。**用 @motionone/dom 等于用上一代产品，排除。**

### 3.7 View Transitions API —— ❌ 场景不匹配

- 模型：对旧/新 DOM 状态做快照，默认交叉淡化，可用 CSS `::view-transition-*` 伪元素自定义。
- 体积：0（原生）。
- 支持：Safari 18+（2024），同文档 `document.startViewTransition()` 可用；macOS 26 满足。
- 短板：**无物理 spring、无手势、无 stagger、无 layout FLIP 语义（只有整页/整区域快照）**；需手动 `startViewTransition(() => 状态突变)` 包一层，与 Pinia 响应式更新的接线别扭。
- 定位：适合「页面/路由切换」这类整体转场，不适合卡片栈的逐卡 spring + 拖拽 + deck 重排。**不采用**，但可留意未来 Safari 对 `interpolate-size` / `@starting-style` 的进一步支持（对需求 C 的高度补间是纯 CSS 红利，与本库无关）。

### 3.8 其他快速评估（调研中顺带确认）

| 库 | 一句话结论 |
|---|---|
| `popmotion`（纯） | 已被 @vueuse/motion / motion 内嵌；不单独用 |
| `@formkit/auto-animate`（已评） | 见 §3.5 |
| `tw-animate-css` | **已在 devDependencies**（^1.4.0），Tailwind 的 `animate-*` 循环脉动/弹跳用，纯 CSS 零 JS，用于需求 E，继续保留 |
| `@vueuse/core` 的 `useTransition` | 已有依赖，能做数值 tween（计数器/进度），但不能做 layout/gesture，仅作微动效补充 |
| `motion`（framer-motion 14 的 DOM 版） | 就是 motion-v 的底层；直接用它则失去 Vue 集成，无必要 |

---

## 4. 结论

### 4.1 选型结论

> **继续 motion-v（`domMax` 或按需 `domAnimation` + 显式 features），不换库、不新增第二套 JS 引擎；用 CSS + `tw-animate-css` 承担「高度补间」与「循环微动效」两类廉价动画。**

理由（按硬约束逐条）：

1. **唯一全能力**：六类需求里 motion-v 全覆盖；其余候选都缺至少两类（@vueuse/motion 缺 layout/gesture/序列，anime 缺 layout/gesture/物理 spring，auto-animate 只有 layout，View Transitions 只有快照转场）。
2. **spring 数学同构已就绪**：`src/lib/motion.ts` 的 `swiftSpring()`（stiffness=ω², damping=2ζω, mass=1）输出的正是 motion-v/`motion-dom` 的 spring schema，零改造直接用于组件 `:transition` 或 `animate()` 的 `transition`。
3. **已声明依赖、零新增**：`package.json` 已有 `motion-v ^2.7.0`；本次是「把死依赖真正接上」，不增加锁文件变动（除可能的升版）。
4. **许可证与维护**：MIT + Framer Motion 团队持续发布；其余候选要么非宽松（GSAP）要么停更（@vueuse/motion）要么归档（@motionone/dom）。
5. **体积可控**：deck 重排若用 CSS transition 实现（见 §5.3），则只需 `domAnimation`（~25.7KB gzip）；需要 `drag`/`layout` 时上 `domMax`（~39.6KB gzip），均为按 feature 摇树后的量，且可用 `LazyMotion` 再懒拆。

### 4.2 组合边界（motion-v + CSS）

| 需求 | 引擎 | 理由 |
|---|---|---|
| A 卡片入/退场（5 档变体） | **motion-v spring/tween**（在 TransitionGroup `:css="false"` 钩子里 `animate()`） | 需要真 spring（bounce 欠阻尼）+ 与 Swift 常量同构 |
| B pile/deck 重排 | **首选 CSS `transition: transform` + `transition: height`；若需「删卡后其余卡片动画归位」再上 motion-v `layout`/AnimatePresence `popLayout`** | deck 只有 3 层、位移单一，CSS 足够且与原生材质同步最稳 |
| C 展开/收起高度 | **CSS grid `grid-template-rows: 0fr → 1fr`**（`interpolate-size` 或显式高度），不用 JS 测高 | 需求原文指定的技巧；零 JS、合成器友好 |
| D 手势拖拽 | **pointer events + `useMotionValue`/`useVelocity`/`useSpring`/`animate()`**（或 `drag` prop 做原型） | 必须精确还原 Swift `dismissDrag` 的 90/220 判决，自定义逻辑比 `drag` 内置弹性更贴合 |
| E 微动效 | **CSS `@keyframes` / `tw-animate-css` / `@vueuse/core` 的 `useTransition`** | 零/极低 JS 成本 |
| F 可复用 spring 预设 | **`swiftSpring()` 单点换算 + 预设注册表**（§5.2） | 与 Swift 常量表一一对应 |

---

## 5. 「多种自定义动画」推荐架构

### 5.1 目录与职责

```
src/lib/animation/
├── types.ts        # 动画预设 schema（纯类型）
├── swift.ts        # Swift 常量表 → motion-v spring 换算（swiftSpring 迁至此，单点源）
├── presets.ts      # 预设注册表：MotionKind → AnimationPreset
└── index.ts        # 对外导出 + useToastMotion() 组合式
```

> 现有 `src/lib/motion.ts` 里的几何常量（`TOAST_METRICS`、`deckScale`、`slideVector`）属于**布局/度量**而非动画，保留原位或迁到 `lib/metrics.ts`；`rubberBand`/`DRAG_*`/`shouldDismissDrag` 属**手势语义**，迁到 `swift.ts` 或独立 `gesture.ts`。本次是报告，不执行迁移。

### 5.2 预设模块设计

**命名**：预设名 = `MotionKind` 原词（`slide | fade | zoom | bounce | none`），与 Rust 下发 `settings.motionEnter/Exit`、Swift `ToastMotion` 完全一致，不做二次映射。

**参数 schema**（`types.ts`）——每个预设声明「进入/退出/重排」三段的 transition + 起止态，过渡参数要么是物理 spring、要么是 tween，`none` 为空：

```ts
// types.ts
import type { MotionKind, ToastPosition } from "@/types";

/** 与 SwiftUI spring(response:dampingFraction:) 同构的物理弹簧。 */
export interface SpringSpec {
  type: "spring";
  response: number;        // Swift response（秒）；换算见 swift.ts
  dampingFraction: number; // Swift dampingFraction
}

export interface TweenSpec {
  type: "tween";
  duration: number; // 秒
  ease: string;     // cubic-bezier() 或缓动名
}

export type TransitionSpec = SpringSpec | TweenSpec | { type: "none" };

/** 一段变体：from = 起始态，to = 静止态。值均为可被 motion 消费的 CSS 值。 */
export interface VariantDef {
  from: Record<string, string | number>;
  to: Record<string, string | number>;
}

/** 一个命名动画预设。enter/exit 对应 Swift ToastMotion.transition(entering:)。 */
export interface AnimationPreset {
  name: MotionKind;
  usesSpring: boolean;              // 对应 Swift usesSpring（决定设置项是否开放弹性）
  enter: { spec: TransitionSpec; variant: VariantDef };
  exit: { spec: TransitionSpec; variant: VariantDef };
  /** 层叠重排（deck FLIP）可选；缺省则组件走 CSS transition。 */
  layout?: TransitionSpec;
}
```

**与 Swift 常量表的映射方式**（`swift.ts`）——一张纯函数表，把 `ToastStyle.swift` 里的魔法数收拢成唯一事实源；`swiftSpring()` 保持现有换算（stiffness=ω², damping=2ζω, mass=1）：

```ts
// swift.ts —— 唯一 Swift 常量映射源（对齐 Sources/.../Toast/ToastStyle.swift）
export function swiftSpring(response: number, dampingFraction: number): SpringSpec {
  const omega = (2 * Math.PI) / response;
  return {
    type: "spring",
    response,
    dampingFraction,
    // 换算出的 motion-v 物理参数（mass=1 谐振子）：
    //   stiffness = omega^2, damping = 2 * dampingFraction * omega
    // 实际喂给 motion 时使用 motionSpring() 展开（见下），这里保留语义字段。
  };
}

/** 展开为 motion-v / motion-dom 的 spring 配置（供 :transition 或 animate() 使用）。 */
export function motionSpring(spec: SpringSpec) {
  const omega = (2 * Math.PI) / spec.response;
  return {
    type: "spring" as const,
    mass: 1,
    stiffness: omega * omega,
    damping: 2 * spec.dampingFraction * omega,
  };
}

/** Swift ToastMotion.animation(milliseconds:damping:entering:) 的等价表。 */
export const SWIFT_MOTION_DEFAULTS = {
  slide:  { dampingFraction: 0.86 },
  bounce: { dampingFraction: 0.68 },
  fade:   {},
  zoom:   {},
  none:   {},
} as const;

/** 弹簧收尾常量（ToastCardView.swift / ToastStackView.swift）。 */
export const SWIFT_SPRINGS = {
  dragBack:      { response: 0.3, dampingFraction: 0.8 },  // 短拖弹回
  pileToggle:    { response: 0.35, dampingFraction: 0.9 }, // pile ↔ 展开
  expandToggle:  { response: 0.3, dampingFraction: 0.9 },  // 卡内展开
  hover:         { response: 0.25, dampingFraction: 0.8 }, // 悬停增亮
} as const;
```

**预设注册表**（`presets.ts`）——`MotionKind → AnimationPreset`，含 Swift 的 `transition` 形状（slide/bounce = offset(slideVector)+opacity；fade = opacity；zoom = scale(0.92 入 / 0.95 出)+opacity；none = identity）：

```ts
// presets.ts
import type { AnimationPreset, SpringSpec, TweenSpec } from "./types";
import { SWIFT_MOTION_DEFAULTS } from "./swift";

export const EASE_OUT = "cubic-bezier(0.16, 1, 0.3, 1)"; // Swift .easeOut

function preset(
  name: AnimationPreset["name"],
  enterSpec: SpringSpec | TweenSpec,
  enterFrom: Record<string, string | number>,
  exitFrom: Record<string, string | number>,
): AnimationPreset {
  return {
    name,
    usesSpring: enterSpec.type === "spring",
    enter: { spec: enterSpec, variant: { from: enterFrom, to: {} } },
    exit: { spec: { type: "tween", duration: 0, ease: EASE_OUT }, variant: { from: {}, to: exitFrom } },
  };
}

/** 预设表：MotionKind → 预设。时长/弹性在调用点由 settings 覆盖。 */
export const MOTION_PRESETS: Record<AnimationPreset["name"], AnimationPreset> = {
  slide:  preset("slide",  { type: "spring", response: 0.42, dampingFraction: 0.86 }, { x: "var(--slide-x)", opacity: 0 }, { x: "var(--slide-x)", opacity: 0 }),
  bounce: preset("bounce", { type: "spring", response: 0.42, dampingFraction: 0.68 }, { x: "var(--slide-x)", opacity: 0 }, { x: "var(--slide-x)", opacity: 0 }),
  fade:   preset("fade",   { type: "tween", duration: 0.42, ease: EASE_OUT }, { opacity: 0 }, { opacity: 0 }),
  zoom:   preset("zoom",   { type: "tween", duration: 0.42, ease: EASE_OUT }, { scale: 0.92, opacity: 0 }, { scale: 0.95, opacity: 0 }),
  none:   preset("none",   { type: "none" }, {}, {}),
};

/** 解析运行时预设：settings 覆盖时长/弹性，none/reduceMotion 短路。 */
export function resolvePreset(
  kind: AnimationPreset["name"],
  ms: number,
  damping: number | null,
): AnimationPreset {
  // 深拷贝，避免污染注册表（并发/多次进卡时各卡拿独立实例）。
  const p = structuredClone(MOTION_PRESETS[kind]);
  if (p.enter.spec.type === "spring") {
    p.enter.spec.response = Math.max(0.05, ms / 1000);
    p.enter.spec.dampingFraction = damping ?? SWIFT_MOTION_DEFAULTS[kind].dampingFraction;
  } else if (p.enter.spec.type === "tween") {
    p.enter.spec.duration = Math.max(0.05, ms / 1000);
  }
  return p;
}
```

> 说明：`x: "var(--slide-x)"` 用 CSS 变量承载 `slideVector(position, 346)` 的方向与幅度（左上/右下 = ±410px，顶/底中 = ±140px），这样同一预设可被 6 个锚点复用，不需要 6 份变体。`var()` 在 motion 里作为关键帧值可被解析。

### 5.3 组件接线方式

**入/退场：保留 Vue `<TransitionGroup :css="false">`，把 `onEnter`/`onLeave` 里的手写 transition 换成 motion-v `animate()`。** 理由：Vue 仍拥有挂载/卸载时机（对应 Swift `animateMembership(removal:)` 的双时钟），改动最小，且不引入 AnimatePresence 与 TransitionGroup 的双重退场协调。

```vue
<!-- ToastStack.vue（示意） -->
<script setup lang="ts">
import { animate } from "motion-v";          // 或 "motion-v" 的 animate 导出
import { resolvePreset, motionSpring } from "@/lib/animation";
import { slideVector } from "@/lib/motion";

function onEnter(el: Element, done: () => void) {
  const s = settings.value;
  const node = el as HTMLElement;
  if (s.reduceMotion || s.motionEnter === "none" || node.classList.contains("group-label")) {
    done(); return;
  }
  const preset = resolvePreset(s.motionEnter, s.motionEnterMs, s.motionDamping);
  const v = slideVector(s.position);
  node.style.setProperty("--slide-x", `${v.x}px`);
  node.style.setProperty("--slide-y", `${v.y}px`);

  const controls = animate(
    node,
    { ...preset.enter.variant.from, opacity: 0 },
    {
      ...preset.enter.variant.to,
      opacity: 1,
      transition: preset.enter.spec.type === "spring"
        ? motionSpring(preset.enter.spec)
        : { duration: preset.enter.spec.duration, ease: preset.enter.spec.ease },
      onComplete: done,          // motion 完成 → 通知 Vue 移除过渡态
    },
  );
  // 挂载即退出的竞态：done 前被 cancel 时也要 done()
  return () => controls.stop();
}
</script>
```

**deck/pile 重排：CSS transition 优先，motion-v layout 作为升级位。**

```vue
<!-- ToastCard.vue 的堆叠位移：CSS transition 即可，不需 JS 引擎 -->
<template>
  <div class="toast-card" :style="{ transform: `translateY(${stackOffset}px) scale(${deckScale(depth)})`, transition: 'transform 320ms cubic-bezier(0.22,1,0.36,1)' }">
```

- 位移目标由 store 的 `computePiled()`/索引算出，卡片自身 `transition: transform` 完成 FLIP 的「invert → play」，无需 motion-v。
- 若日后要做「删卡后其余卡片**平滑补位归位**」（不是淡入淡出，而是持续位移），升级为 `<AnimatePresence mode="popLayout">` + `:layout`：离开元素脱离文档流、剩余元素自动 FLIP 归位，`transition` 用 `motionSpring(SWIFT_SPRINGS.pileToggle)`。

**展开/收起高度：grid 技巧（需求 C 原话），组件只切换 class。**

```vue
<template>
  <!-- 0fr→1fr 高度补间：无需 JS 测高，无需动画库 -->
  <div class="toast-body-slot" :class="expanded ? 'grid-rows-[1fr]' : 'grid-rows-[0fr]'">
    <div class="overflow-hidden">
      <div class="toast-card-body"><!-- 内容 --></div>
    </div>
  </div>
</template>
<style scoped>
.toast-body-slot { display: grid; transition: grid-template-rows 300ms cubic-bezier(0.22,1,0.36,1); }
</style>
```

**微动效：CSS + 已有 `tw-animate-css`，不引入 JS。**

```vue
<!-- ProgressCapsule.vue：进度条直接 width 过渡；循环脉动用 tw-animate-css -->
<div class="toast-progress-fill" :style="{ width: `${clamped()*100}%`, transition: 'width 200ms ease-out' }" />
<span v-if="pulsing" class="animate-pulse">…</span>
```

### 5.4 gesture 动画实现路径

**目标**：精确还原 Swift `ToastCardView.dismissDrag`（`DragGesture(minimumDistance:12)`，90pt 内线性、90pt 后 0.5 阻力、`predictedEndTranslation` 220pt 判决、过线 `withAnimation(exit)` 滑走、否则 `spring(response:0.3, dampingFraction:0.8)` 弹回）。

**路径（推荐：保留 pointer 事件，用 motion-v 低阶值做「跟手 + 收尾」）**——现有 `ToastCard.vue` 的 pointer 数学（`rubberBand`/`shouldDismissDrag`/速度投影）是 Swift 语义的精确移植，**不要用 `drag` prop 重写**（`dragElastic` 只有均匀橡皮筋，无法表达「90pt 前线性、之后 0.5」的两段规则）。保留判定逻辑，只把「样式手写 + 320ms setTimeout」替换为 motion-v 的 motion value + `animate()` 收尾：

```ts
// ToastCard.vue（示意迁移）
import { animate, useMotionValue, useSpring, useTransform, useVelocity } from "motion-v";
import { SWIFT_SPRINGS, motionSpring } from "@/lib/animation";

const dragX = useMotionValue(0);          // 跟手位移（直接 set，无抖动）
const velocityX = useVelocity(dragX);     // 速度投影（替换手工 lastX/lastT 差分）
const opacity = useTransform(dragX, [0, DRAG_OPACITY_RANGE], [1, 0.25]);

// 拖拽跟手：pointermove 里直接写 motion value，绑定到卡片 :style 的 x/opacity
function onPointerMove(e: PointerEvent) {
  // …minimumDistance 12 判定同现状…
  const banded = rubberBand(sign * dx);
  dragX.set(sign * banded);               // 跟手（无动画、无样式抖动）
}

function onPointerUp() {
  if (shouldDismissDrag(travel, predicted)) {
    toastStore.setDragOffset(id, dragX.get());
    // 惯性滑走：从当前值续滑到屏幕外，跑 settings.motionExitMs 的 easeOut
    animate(dragX, sign * (CARD_WIDTH + 64), {
      duration: settings.value.motionExitMs / 1000,
      ease: EASE_OUT,
      onComplete: () => toastStore.dragDismiss(id),
    });
  } else {
    // 短拖弹回：物理弹簧收尾，替换原 320ms setTimeout + CSS transition
    animate(dragX, 0, motionSpring(SWIFT_SPRINGS.dragBack));
  }
}
```

```vue
<template>
  <div class="toast-card" :style="{ x: dragX, opacity }" … />
</template>
```

**为什么这样切**：
- `useMotionValue` 的 `set()` 是同步写、零动画——比现在的 `dragX.value = …` + Vue 响应式重渲染更轻，且直接驱动 compositor 上的 transform，跟手不掉帧。
- `useVelocity` 用 motion 内部的速度追踪，替换手工 `(clientX-lastX)/dt` 差分，`predictedEndTranslation` 的 110ms 投影直接乘时间。
- `animate(motionValue, target, spring)` 让「弹回」从「CSS transition + 猜时长 + setTimeout 清标志」变成真物理弹簧收尾，`springBack` 标志与定时器全部删除。
- **原生材质同步不受影响**：motion value 驱动的 transform 同样被 `getBoundingClientRect()` 读到（`useFrameReporter` 不改）。

**备选路径（原型/快速验证用）**：直接上 `<Motion :drag="'x'" :drag-constraints :drag-elastic :on-drag-end>`，拿 `offset`/`velocity` 在 `onDragEnd` 做同样的 90/220 判决。适合先验证手感，但两段橡皮筋规则需在 `onDrag` 里手动钳制，最终仍会滑回上面的自定义方案。

### 5.5 reduce-motion 全局门

- store 的 `settings.reduceMotion` 继续作为总闸（Rust 下发），在 `resolvePreset` 与 `onEnter/onLeave` 首行短路。
- motion-v 提供 `useReducedMotion()`（读 `prefers-reduced-motion`）与 `MotionConfig reducedMotion`，作为**第二道**系统级兜底，覆盖「系统开减少动态但 App 设置未开」的场景。
- 微动效的 `animate-pulse` 等 CSS 类同样受 `:data-reduce-motion` 属性选择器抑制（`ToastStack.vue` 已挂 `:data-reduce-motion`）。

---

## 6. 落地清单（供后续实施，非本次改动）

1. 新建 `src/lib/animation/{types,swift,presets,index}.ts`；把 `swiftSpring`、`SWIFT_SPRINGS`、`SWIFT_MOTION_DEFAULTS` 收拢为单点源。
2. `ToastStack.vue` 的 `onEnter/onLeave` 换成 `animate()` + `resolvePreset()`（§5.3），删掉 rAF 双帧与 `setTimeout(done)` 的时长猜测。
3. `ToastCard.vue` 手势改 `useMotionValue/useVelocity/useTransform/animate`（§5.4），删 `springBack`/`dragX ref`/`lastX/lastT`/320ms 定时器。
4. deck 重排保持 CSS transition；如升级 layout 动画，引入 `LazyMotion` + 显式 `features`（drag/layout）以控体积。
5. 展开/收起改用 grid `0fr→1fr`；循环脉动走 `tw-animate-css`（已在依赖）。
6. 升 `motion-v` 至当前 2.8.0（可选），并做一次「domAnimation vs domMax」的摇树体积实测，选最小入口。

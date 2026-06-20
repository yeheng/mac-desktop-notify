# macOS 26 Liquid Glass 设计与实现

本文件汇总从 Apple WWDC25 Session 219《Meet Liquid Glass》、Apple HIG Materials、
`window-vibrancy` 0.7.1 crate 源码中提取的设计规范，并描述本项目（desktop-notify-tauri）
的落地策略。

---

## 1. 设计规范（来自 Apple 官方）

### 1.1 Liquid Glass 是什么
> Liquid Glass is a new digital meta-material that dynamically bends and shapes light.
> It behaves and moves organically, like a lightweight liquid.

它不是物理玻璃的复刻，而是一种**数字超材料**：实时弯折、塑造、汇聚光线（**Lensing**），
而非像 iOS 7 的 blur 那样散射光。由此提供层次分离，同时让下层内容透上来。

### 1.2 核心光学 / 物理特性
| 特性 | 说明 | 我们的 CSS 对应 |
|------|------|----------------|
| **Lensing 透镜** | 边缘汇聚光线，形成轮廓 | 内描边高光（`box-shadow inset` + 渐变 border） |
| **Highlights 高光** | 环境光随几何在表面流动 | 顶部 `linear-gradient` 高光、hover 加强 |
| **Shadows 阴影** | 元素感知背后内容：压在文字上时阴影加深，压在浅底上时变浅 | 分层 `box-shadow`（玻璃不会深黑） |
| **Inner illumination 内发光** | 交互时从指尖扩散光晕 | `:active` 内发光 + 快速过渡 |
| **Adaptivity 自适应** | 小元素（导航栏）会明暗翻转；大元素（菜单/侧栏）不翻转但加深 | `prefers-color-scheme` + 透明度调整 |

### 1.3 两个变体（NSGlassEffectViewStyle）
- **Regular（0）**：最常用，全套自适应效果，任何尺寸/背景/上层内容都可。
  → 用于：**dashboard、settings 主面板**。
- **Clear（1）**：永久更透明，无自适应，**必须配 dimming 层**保证文字可读。
  适用于：媒体内容之上、内容层不受 dimming 影响、上层内容足够粗亮。
  → 本项目暂不使用 Clear（通知正文多变，不满足三条件）。

其它可用 style 枚举（仅 Regular/Clear 官方支持，其余 API 不保证）：
`NotificationCenter = 9`、`Sidebar = 16`、`Inspector = 18`、`Control = 19`、`Popover`、`Menu`...

### 1.4 使用原则（关键约束）
1. **玻璃只用于漂浮在内容之上的「导航/控件」层**。内容层（表格、列表项正文）**不要**用玻璃，
   否则会和导航层竞争、破坏层级。
2. **永远不要 glass on glass**。叠层时上层用 fill / transparency / vibrancy，而非再贴一层玻璃。
3. **着色（tint）只用于强调主要动作**。不要把所有按钮都 tint，否则什么也不突出。
4. **失焦时玻璃视觉后撤**（macOS 窗口失焦降亮度）。
5. **与内容保持分离**：稳态下避免内容与玻璃相交，应重排或缩放内容。
6. **圆角同心嵌套**：玻璃控件要与窗口/容器的圆角同心（concentric）。

### 1.5 自适应与无障碍（系统级，自动生效）
- **Reduced Transparency** → 玻璃更磨砂，遮更多背景。
- **Increase Contrast** → 玻璃变纯黑/纯白 + 对比描边。
- **Reduce Motion** → 减弱动效、禁用弹性。

我们 CSS 侧也要尊重这三个媒体查询。

---

## 2. 实现策略

### 2.1 双层模型
真正的毛玻璃（透过窗口看到桌面/其他 app）**无法用 CSS `backdrop-filter` 实现**，
因为 Tauri webview 只能看到自己的内容。所以分两层：

| 层 | 技术 | 作用 |
|----|------|------|
| **窗口级** | Rust `window-vibrancy` crate，调用原生 `NSGlassEffectView` / `NSVisualEffectView` | 真正透过窗口的毛玻璃 |
| **控件级** | CSS（半透明 + 内描边高光 + 分层阴影 + 圆角 + 内发光） | 模拟 Liquid Glass 的 lensing/高光/阴影 |

### 2.2 版本降级
| macOS 版本 | 窗口材质 |
|-----------|---------|
| **26.0+** (Tahoe) | `apply_liquid_glass` + `NSGlassEffectViewStyle::Regular` |
| **11.0–25.x** (Big Sur+) | `apply_vibrancy` + `NSVisualEffectMaterial::UnderWindowBackground` |
| < 11 | no-op，CSS 退回纯色背景 |

### 2.3 三窗口的玻璃配置
| 窗口 | style / material | transparent | decorations | 圆角 |
|------|-----------------|-------------|-------------|------|
| **dashboard**（通知中心） | `Regular` / `NotificationCenter` | true | true | 大圆角面板 |
| **banner**（横幅） | `Regular`（无边框透明） | true | false | 大圆角卡片 |
| **settings**（设置） | `Regular` / `Sidebar` | true | true | 大圆角面板 |

### 2.4 CSS 设计 token（见 `src/style.css`）
```css
/* 玻璃层（控件/卡片漂浮在 vibrancy 之上） */
--glass-bg:          rgba(255,255,255,0.55);
--glass-bg-strong:   rgba(255,255,255,0.72);
--glass-border:      rgba(255,255,255,0.65);
--glass-highlight:   rgba(255,255,255,0.9);
--glass-shadow:      0 1px 0 rgba(255,255,255,.5) inset, 0 8px 24px rgba(0,0,0,.18);
--glass-radius:      16px;
--glass-radius-sm:   12px;
--pill-radius:       999px;
```
暗色模式对应调低 alpha 并改色相。

### 2.5 无障碍降级
```css
@media (prefers-reduced-transparency: reduce) {
  :root { --glass-bg: var(--bg-card); }   /* 退回不透明卡片 */
}
@media (prefers-contrast: more) {
  :root { --glass-border: var(--text-primary); }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition: none !important; animation: none !important; }
}
```

---

## 3. 落地清单
- [x] Cargo.toml 加 `window-vibrancy = "0.7"`
- [x] `src-tauri/src/glass.rs`：按 macOS 版本分发原生材质
- [x] `lib.rs` setup：三窗口应用玻璃
- [x] `tauri.conf.json`：dashboard/settings `transparent: true`
- [x] `src/style.css`：玻璃 token + 容器透明 + 降级
- [x] 组件改造：BaseNotifyCard / BannerGroup / DashboardView / SettingsView / MarkdownBody
- [x] 修复上一轮 review 中的暗色配色 / 图标 / 文案问题（一并完成）

## 4. 参考资料
- WWDC25 Session 219: Meet Liquid Glass — https://developer.apple.com/videos/play/wwdc2025/219/
- Adopting Liquid Glass — https://developer.apple.com/documentation/appropriates/adopting-liquid-glass
- NSGlassEffectView — https://developer.apple.com/documentation/appkit/nsglasseffectview
- window-vibrancy 0.7.1 — https://github.com/tauri-apps/window-vibrancy


### 第一部分：Linus 风格的问题剖析与决策

#### Layer 1: Data Structure Analysis (数据结构分析)

* **通知核心数据模型**：

    ```swift
    struct NotchNotification: Identifiable, Sendable {
        let id: UUID
        let title: String
        let bodyMarkdown: String
        let urgency: UrgencyLevel // .low, .normal, .critical
        let timestamp: Date
    }
    ```

* **流向与数据所有权**：
  * 在内存中维护一个极简的 FIFO（先进先出）环形队列（`NotificationQueue`），最大容量限制为 10 条（防止内存泄露）。
  * `NotificationManager` 必须是 `@MainActor` 隔离的单例，负责驱动 SwiftUI 的视图更新，并触发 `DynamicNotchKit` 的展开逻辑。

#### Layer 2: Edge Case Identification (边界情况识别)

* **Markdown 长度失控**：如果用户用 CLI 塞入一篇 5000 字的 Markdown 文章，刘海会被直接撑爆，界面会变得极度恶心。
  * *消除特例*：在 SwiftUI 渲染层加上严格限制——最大高度固定（例如 `maxHeight: 250`），并嵌套在带有自适应隐藏滚动条的 `ScrollView` 中。或者提供 `lineLimit(6)`，超过部分渐变截断。
* **高频并发推送冲突**：两个后台脚本在一毫秒内同时推送通知。
  * *消除特例*：不要让刘海“收起再展开”。利用 `DynamicNotchKit` 的 `skipIntermediateHides: true` 机制，当检测到队列中有新通知时，直接在展开状态下进行内容过渡动画，而不是反复折叠。

#### Layer 3: Complexity Audit (复杂度审计)

* **如何接收通知？**
  * *愚蠢的设计*：在应用内跑一个本地 HTTP 服务器（监听 Port 8080）。这不仅增加了网络套接字（Socket）管理的复杂度，还容易引发防火墙弹窗和端口冲突。
  * *优雅的极简设计*：注册 macOS 自定义 URL 协议（URL Scheme），例如 `notch-notify://push?title=xxx&body=yyy`。这不需要任何后台网络端口，系统内核原生调度，开发者在终端运行 `open "notch-notify://..."` 就能直接推送，甚至可以用 Shell 脚本、Raycast 瞬间集成。这才是 Unix 的极简品味。

#### Layer 4: Breaking Change Analysis (破坏性变更分析)

* `DynamicNotchKit` 自 1.0.0 版本起完全支持 Swift 6 的严格并发性检查（Strict Concurrency）。你的 `NotificationManager` 必须确保跨线程的安全数据传递。当外部 URL 触发通知写入时，必须异步调度回 `@MainActor`，否则在 Swift 6 下会编译报错。

#### Layer 5: Practicality Validation (实用性验证)

* 不要去用外部重型的 Markdown 渲染库（例如 cmark-gfm 的 Swift 封装）。那会引入数兆大小的 C 语言二进制依赖和极易引起崩溃的野指针。
* macOS 13+（DynamicNotchKit 要求的最低版本）的 SwiftUI `Text` 和 `AttributedString` 已经原生且安全地支持 Markdown（解析行内加粗、斜体、代码、链接等）。我们直接使用 Apple 的原生沙盒解析器。

---

```
【核心判断】
值得做。系统通知无法优雅展示代码片段和格式化文本，此项目能极大地提升开发者的开发上下文切换体验。

【关键洞察】
- 传输架构：抛弃本地 Socket 监听，改用 macOS 注册原生 URL Scheme，零性能损耗、零端口占用。
- 渲染架构：拒绝第三方 Markdown 渲染库，纯用 SwiftUI AttributedString 驱动，零依赖，安全高效。
- 窗口管理：依托 DynamicNotchKit 处理刘海自适应，规避 VoiceOver 和 KeyFocus 系统焦点抢占 Bug。

【Linus式方案】
1. 注册 URL Protocol 收集通知请求。
2. 将数据送入主线程的 MainActor 优先级队列。
3. 渲染使用 AttributedString 行内 Markdown 解析。
4. 调用 DynamicNotchKit 的 `expand()` 展开，结合 `boring.notch` 的磨砂毛玻璃半透明材质。
```

---

### 第二部分：核心实现代码（Good Taste 范例）

这是一个符合“好品味”标准的极简通知中心核心实现：

#### 1. 极简 Markdown 渲染器 (SwiftUI)

```swift
import SwiftUI

struct MarkdownNotificationView: View {
    let title: String
    let bodyMarkdown: String
    let urgency: UrgencyLevel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                    .bold()
                Spacer()
                // 仿 Boring.Notch 渐变色气泡指示器
                Circle()
                    .fill(urgency.color)
                    .frame(width: 8, height: 8)
            }
            
            Divider()
                .background(Color.white.opacity(0.15))
            
            // 安全、无依赖的原生 Markdown 渲染
            ScrollView {
                if let attributedString = try? AttributedString(markdown: bodyMarkdown, options: .init(interpretingSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributedString)
                        .font(.system(.body, design: .monospaced)) // 方便展示代码片段
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.white.opacity(0.9))
                } else {
                    Text(bodyMarkdown)
                        .font(.body)
                }
            }
            .frame(maxHeight: 180) // 严格的高度边界，防止撑爆
        }
        .padding(16)
        .frame(width: 320) // 标准刘海展开宽度
        .background(VisualEffectView(material: .ultraThinMaterial, blendingMode: .withinWindow)) // 磨砂毛玻璃
        .cornerRadius(16)
    }
}
```

#### 2. `SecureNotchPanel` 防焦点抢占设计

必须在子类化 `NSPanel` 时封锁键盘焦点，确保绝不干扰主屏幕的正常输入：

```swift
class SecureNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }  // 坚决不抢夺键盘输入焦点
    override var canBecomeMain: Bool { false } // 坚决不成为当前主活动窗口

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        // 彻底解决 VoiceOver 卡死系统的 Bug
        self.setAccessibilityElement(false)
        self.setAccessibilityRole(.unknown)
    }
}
```

---

### 第三部分：完整的中文任务清单 (Actionable Task List)

#### 任务 1：配置项目的 URL Scheme 与通知监听器

* **任务目标**：注册自定义 URL Scheme `notch-notify://`，能解析来自外部的通知参数（Title & Body）。
* **上下文与理由**：不使用本地端口监听器，确保系统的网络沙盒安全性及无网络环境下的极速响应。
* **影响范围**：
  * 修改项目 `Info.plist`，添加 `URL Types`。
  * 在 Host 应用的 `AppDelegate` 或 SwiftUI `@main` 入口拦截 URL。
* **技术方案**：
    1. 在 `Info.plist` 中，将 URL Schemes 声明为 `notch-notify`。
    2. 在 App 入口使用 `.onOpenURL` 拦截事件：

        ```swift
        .onOpenURL { url in
            guard url.scheme == "notch-notify",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let queryItems = components.queryItems else { return }
            
            let title = queryItems.first(where: { $0.name == "title" })?.value ?? "Notification"
            let body = queryItems.first(where: { $0.name == "body" })?.value ?? ""
            NotificationManager.shared.push(title: title, body: body)
        }
        ```

* **测试策略**：
  * 在终端中执行：`open "notch-notify://push?title=GitPush&body=**MainBranch**%20build%20\`success\`"`，检查 Host 应用能否无延迟捕获。
* **验收标准**：
  * [ ] 无论应用在前台还是后台，上述终端命令能 100% 触发应用内的回调。
  * [ ] URL 中的中文与特殊 Markdown 语法符号（已转义）能被正确还原。
* **严格限制**：严禁打开任何 TCP 端口监听，避免触发 macOS 任何本地防火墙拦截警告。

---

#### 任务 2：使用 DynamicNotchKit 集成并配置转场动画

* **任务目标**：将我们的 Markdown 视图绑定到 `DynamicNotch` 实例中，并定制过渡动画参数。
* **上下文与理由**：默认的展示逻辑可能不够“灵动”，我们需要利用 DynamicNotchKit 2026 年最新提供的 `DynamicNotchTransitionConfiguration` 来做状态间的平滑转换。
* **影响范围**：
  * `NotificationManager.swift` 核心控制逻辑。
* **技术方案**：
    1. 引入 Swift 包依赖 `https://github.com/MrKai77/DynamicNotchKit`。
    2. 初始化 `DynamicNotch` 实例，将自定义的 `MarkdownNotificationView` 传入：

        ```swift
        @MainActor
        class NotificationManager {
            static let shared = NotificationManager()
            private var activeNotch: DynamicNotch?

            func push(title: String, body: String) {
                // 实例化
                let notch = DynamicNotch(style: .auto) {
                    MarkdownNotificationView(title: title, bodyMarkdown: body, urgency: .normal)
                }
                
                // 1.0.0+ 新配置：开启直接跳转，避免折叠再展开的抽搐
                notch.transitionConfiguration = .init(
                    openingAnimation: .spring(duration: 0.35, bounce: 0.1),
                    skipIntermediateHides: true
                )
                
                self.activeNotch = notch
                
                Task {
                    await notch.expand() // 展开刘海
                }
            }
        }
        ```

* **测试策略**：
  * 快速、连续地触发多条通知，验证灵动岛内容是否是在“展开状态”下平滑渐变切换（Cross-dissolve），而不是收缩、再弹开。
* **验收标准**：
  * [ ] 内容切换过程中，窗口无瞬间的闪烁与卡顿。
  * [ ] 没有物理刘海的电脑（如 iMac / 旧 Mac mini）能自动、优雅地以降级后的 `floating` 样式居中弹窗。
* **严格限制**：必须在 `@MainActor` 线程隔离下进行窗口的生命周期操作，严禁在后台线程直接触发 UI 变动。

---

#### 任务 3：实现 Boring.Notch 风格的物理手势交互 (拖拽丢弃与悬停保持)

* **任务目标**：鼠标移动到展开的刘海上时保持展开，离开后计时自毁；支持拖拽或轻扫快速丢弃通知。
* **上下文与理由**：如果用户正在阅读 Markdown 中的代码，通知突然消失是非常糟糕的体验。悬停（Hover）必须能自动打断自毁定时器。
* **影响范围**：
  * SwiftUI 视图的外层修饰符。
* **技术方案**：
    1. 在视图最外层加上 `onHover` 监听：

        ```swift
        .onHover { isHovered in
            if isHovered {
                NotificationManager.shared.pauseAutodismissTimer()
            } else {
                NotificationManager.shared.resumeAutodismissTimer()
            }
        }
        ```

    2. 加入轻微的 Haptic 反馈（若设备支持）：当鼠标触碰刘海边缘，调用 `NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)`。
* **测试策略**：
  * 触发一条设置了 3 秒自动消失的通知。在第 2 秒时将鼠标指针悬停在灵动岛上，观察它是否保持常亮；将指针移开，确认 3 秒后它正常收起。
* **验收标准**：
  * [ ] 指针悬停逻辑能精准触发，且不干扰鼠标对 Markdown 文本的选中和点击复制操作。
  * [ ] 在支持的 MacBook Pro 触控板上，进入刘海边缘时能感受到轻微、清脆的震动回馈。
* **严格限制**：不要在 `onHover` 回调中执行复杂的计算，仅改变一个本地的布尔状态标志位。

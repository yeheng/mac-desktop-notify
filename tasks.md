#### 任务 1：修复脚本超时后并发槽位泄漏

- **任务目标**：防止超时泄漏的 JavaScript 线程永久占死 `ScriptRunner` 的并发槽位，确保脚本引擎在发生超时后依然能够正常响应后续请求。
- **背景与原因**：当前 `ScriptEngine.tryAcquireSlot` 检查的是 `aliveThreadCount`，而该计数的递减依赖线程内的 `defer`。在死循环（如 `while(true){}`) 场景下，看门狗触发超时并切断了响应，但底层线程卡在 JSC 中永远不退出，导致 `aliveThreadCount` 永远无法扣减。发生 4 次超时后，并发槽位耗尽，所有后续脚本执行均被拒并返回 `"busy"`。
- **影响范围**：`Sources/MacDesktopNotify/ScriptRunner.swift`、`Tests/MacDesktopNotifyTests/ScriptRunnerTests.swift`。
- **技术方案**：
  1. 将“逻辑执行槽位”（`activeExecutions`，上限 4）与“底层游离僵尸线程计数”（`zombieThreads`）在概念与数据结构上彻底分离。
  2. 启动脚本执行时占用 1 个逻辑槽位；一旦看门狗超时（`budget` 耗尽触发 `ResumeOnce`），**无论底层线程是否退出，立即释放该逻辑槽位**，并发出 OSLog 警告记录僵尸线程。
  3. 增加兜底安全线：若游离僵尸线程累计超过阈值（如 8 个），则临时熔断并拒绝新任务，防止极端情况下虚拟内存被耗尽，但绝不能因为单次超时直接永久扣减槽位。
- **测试策略**：
  - 编写单元测试：注入一个含死循环 `while(true){}` 的脚本，将其 `budget` 设为 50ms。
  - 连续执行 5 次该脚本，断言前 4 次在 50ms 后均返回 `error: "timeout"`，第 5 次依然能够正常进入调度而非直接报错 `"busy"`。
- **验收标准**：
  - [x] 死循环脚本超时后，下一次合法脚本执行能够立刻获得槽位并成功执行。
  - [x] 现有的 `testConcurrencyCapRejectsFifth` 测试依然通过（并发执行中的限制依然有效）。
- **严格约束**：禁止修改 `ScriptRunner.run` 的公有 API 签名；禁止改变 `ScriptOutcome` 的结构。

---

#### 任务 2：将 `NotchPresenter` 中的全屏检测移除主线程
- **任务目标**：消除在 `@MainActor` 上同步执行 `CGWindowListCopyWindowInfo` 造成的 UI 丢帧与潜在卡顿。
- **背景与原因**：`NotchPresenter.frontmostWindowIsFullscreen` 同步遍历全系统窗口列表。该操作依赖与 WindowServer 的同步 IPC。在高负载、外接显示器插拔或高频鼠标移动触发探测时，主线程可能发生数十毫秒的阻塞。
- **影响范围**：`Sources/MacDesktopNotify/NotchPresenter.swift`。
- **技术方案**：
  1. 将 `frontmostWindowIsFullscreen` 改造为非主线程执行的异步探测函数（运行在后台队列/Task.detached）。
  2. 在 `fullscreenResult` 缓存过期时，启动后台 Task 获取并更新缓存值，主线程探测若遇缓存过期，优先返回上一次的快照或由后台任务完成后通过事件通知 MainActor 刷新。
  3. 充分利用 `NSWorkspace.activeSpaceDidChangeNotification` 与 `NSWorkspace.didActivateApplicationNotification` 作为强失效信号，避免依赖鼠标高频移动轮询。
- **测试策略**：
  - 在无窗口服务器环境的 CI 单元测试中验证 mock/fallback 逻辑。
  - 模拟多屏切换与前后景应用切换，验证 `probeDisplaySuppressed` 返回值的正确性与缓存有效时间。
- **验收标准**：
  - [x] `MainActor` 调用路径上不再出现同步的 `CGWindowListCopyWindowInfo` 调用。
  - [x] 全屏应用激活时，卡片展示与 Compact Pill 能够按既定规则被正确抑制。
- **严格约束**：禁止更改 `NotchPresenting` 协议中 `probeDisplaySuppressed()` 的签名；禁止引入第三方系统监控库。

---

#### 任务 3：收敛 `panelEntered` 状态至 `PointerState`
- **任务目标**：消除 `NotificationManager` 中裸露的 `panelEntered` 状态，统一由 `PointerState` 管理指针与交互生命周期。
- **背景与原因**：当前指针位置由 `PointerState` 描述，但卡片是否被用户悬停看过的判定（`panelEntered`）却作为一个单独的 `@ObservationIgnored var panelEntered` 挂在 `NotificationManager` 上，散落于 `reduce` 和 `settleDisplay` 之中，破坏了数据结构的内聚性。
- **影响范围**：
  - `Sources/MacDesktopNotify/PointerState.swift`
  - `Sources/MacDesktopNotify/NotificationManager.swift`
  - `Sources/MacDesktopNotify/NotificationManager+Pointer.swift`
  - `Sources/MacDesktopNotify/NotificationManager+Presentation.swift`
- **技术方案**：
  1. 在 `PointerState` 中加入字段 `var panelEverEntered: Bool = false`。
  2. 当 `reduce` 收到 `.panelHoverBegan` 意图时，将 `panelEverEntered` 置为 `true`。
  3. 当触发重置意图（如卡片折叠/销毁 `.reset`）或通过显式方法时重置该标志。
  4. 移除 `NotificationManager.panelEntered` 属性及其所有直接赋值点，将判定统一委托给 `pointer.panelEverEntered`。
- **测试策略**：
  - 运行已有的 `DismissRulesTests`、`ActionHoldTests` 和 `IslandStateTests`，重点验证：
    - 信息卡进入后离开立即收起的规则（`testLeaveAfterEnteringCollapsesCard`）；
    - 仅靠近未进入激活区不提前触发退役的规则。
- **验收标准**：
  - [x] `NotificationManager` 中彻底删除 `var panelEntered` 属性。
  - [x] 所有与离开收起相关的行为与原先完全一致，测试全部绿色。
- **严格约束**：不修改外部调用 `setHovering` 和 `setPointerNearIsland` 的公开接口。

---

#### 任务 4：防护 Unix Domain Socket 路径长度溢出
- **任务目标**：防止因用户的 `Application Support` 路径过深导致 Unix 域套接字 `sun_path` 截断或静默绑定失败。
- **背景与原因**：macOS 下 `sockaddr_un.sun_path` 的最大长度固定为 104 字节。若用户目录名过长或存在多层嵌套，`defaultSocketPath`（拼接在 Application Support 下）可能超过 104 字节，导致 `socket(AF_UNIX)` 或 `NWListener` 报错无法监听。
- **影响范围**：`Sources/MacDesktopNotify/APIListenerService.swift`。
- **技术方案**：
  1. 在 `APIListenerService` 初始化及路径计算阶段，对目标路径字节长度进行断言/检查。
  2. 若 `path.utf8.count >= 104`，提供一个经过规范哈希缩短且安全的备用路径（例如存放于 `/tmp/mdn-<uid>-<hash>.sock`），并在控制台/诊断状态中记录明确的路径改向提示。
- **测试策略**：
  - 编写单元测试：传入一个超过 120 字节的超长临时路径，验证服务能够优雅降级处理或给出明确的 `socketError`，绝不发生内存越界或未定义行为。
- **验收标准**：
  - [x] 超长路径不再导致不可解释的监听失败。
  - [x] 正常路径依然默认保留在 `Application Support` 原定位置，保证老客户端向后兼容。
- **严格约束**：若路径在 103 字节以内，严禁修改当前默认 socket 路径规则。
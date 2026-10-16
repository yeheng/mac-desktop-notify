/**
 * 与 Rust 侧 `model.rs` / `events.rs` 对应的线格式（serde camelCase）。
 * 字段名与 Swift `CardPayload` / `HistoryItemDTO` 保持一致。
 */

export type Urgency = "low" | "normal" | "critical";

/** push 的 `island` 字段：发送方驱动的状态行。 */
export interface StatusLine {
  text?: string | null;
  icon?: string | null;
  progress?: number | null;
}

/**
 * 操作按钮。XOR 语义（url / script / callback 三选一）在 Rust 侧
 * `norm_actions` 已定型，这里保持扁平 wire 形状与 API 一致。
 */
export interface NotificationAction {
  label: string;
  url?: string | null;
  script?: string | null;
  callback?: string | null;
  wantsComment: boolean;
  args?: unknown;
}

/** 屏上一张卡片 = CardPayload + 交互态（Swift `Presentation`）。 */
export interface Presentation {
  id: string;
  title: string;
  bodyMarkdown: string;
  urgency: Urgency;
  timeout: number | null;
  /** Unix 纪元秒（Swift HistoryItemDTO.timestamp 同约定）。 */
  timestamp: number;
  actions: NotificationAction[];
  group: string | null;
  tags: string[];
  clickUrl: string | null;
  island: StatusLine | null;
  /** 推送触发的回填脚本名（Swift CardPayload.script；null = 无）。 */
  script: string | null;
  occurrences: number;
  read: boolean;
  /** 系统通知中心镜像档（null = 跟随应用设置）。 */
  native: boolean | null;
  expanded: boolean;
}

export type ToastPosition =
  | "topRight"
  | "bottomRight"
  | "topCenter"
  | "topLeft"
  | "bottomLeft"
  | "bottomCenter";

export type MotionKind = "slide" | "fade" | "zoom" | "bounce" | "none";

export type QuietMode = "off" | "historyOnly" | "criticalOnly";

/** Rust `config.rs` 下发的运行时设置（AppSettings 的呈现面子集）。 */
export interface ToastSettings {
  position: ToastPosition;
  material: string;
  opacity: number;
  motionEnter: MotionKind;
  motionExit: MotionKind;
  motionEnterMs: number;
  motionExitMs: number;
  motionDamping: number | null;
  dwellSeconds: number;
  contentFontSize: number;
  ageOutCriticals: boolean;
  quietMode: QuietMode;
  reduceMotion: boolean;
  soundEnabled: boolean;
  hapticsEnabled: boolean;
}

/** `toast://state` 事件载荷。 */
export interface ToastState {
  presentations: Presentation[];
  stackExpanded: boolean;
  settings: ToastSettings;
  unreadCount: number;
  silenced: boolean;
  /** 栈窗口的最大内容高度（逻辑点）：Rust 按 60% 屏幕可见高度钳制，
   *  展开态正文的滚动预算由它推导（Swift ToastLayout.maxHeightFraction）。 */
  maxStackHeight: number;
}

/** 一个原生材质面的几何（前端每帧上报，material.rs 维护 NSVisualEffectView）。 */
export interface SurfaceFrame {
  /** 卡片 id、`edge-{depth}` 或 `close-{cardId}`。 */
  id: string;
  /** 窗口坐标（CSS 像素 = 逻辑点，左上原点）。 */
  x: number;
  y: number;
  width: number;
  height: number;
  /** 0…1，会再乘以设置的材质透明度（卡片与边缘）。 */
  alpha: number;
  /** 圆角半径；`topOnly` 时只圆上两角。 */
  radius: number;
  topOnly: boolean;
}

/**
 * 通知中心状态store。
 *
 * Rust 侧 manager.rs 是唯一真源（对应 Swift NotificationManager）：栈成员、
 * 展开态、dwell 计时、已读/退役都在 Rust。本 store 只做两件事：
 *   1. 镜像 `toast://state` 事件；
 *   2. 把交互意图转发成 Tauri 命令。
 *
 * 退出动画不在这里：卡片离开 DOM 由 Vue TransitionGroup 的 leave 钩子承担
 * （对应 Swift `animateMembership(removal:)` 的 removal transition），
 * 原生材质面在整段退场期间由 useFrameReporter 持续上报。
 */
import { reactive } from "vue";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type {
  NotificationAction,
  Presentation,
  SurfaceFrame,
  ToastSettings,
  ToastState,
} from "@/types";

const DEFAULT_SETTINGS: ToastSettings = {
  position: "topRight",
  material: "popover",
  opacity: 1,
  motionEnter: "slide",
  motionExit: "slide",
  motionEnterMs: 420,
  motionExitMs: 260,
  motionDamping: null,
  dwellSeconds: 5,
  contentFontSize: 13,
  ageOutCriticals: true,
  quietMode: "off",
  reduceMotion: false,
  soundEnabled: true,
  hapticsEnabled: true,
};

interface StoreState {
  presentations: Presentation[];
  stackExpanded: boolean;
  settings: ToastSettings;
  unreadCount: number;
  silenced: boolean;
  maxStackHeight: number;
  ready: boolean;
}

const state = reactive<StoreState>({
  presentations: [],
  stackExpanded: false,
  settings: { ...DEFAULT_SETTINGS },
  unreadCount: 0,
  silenced: false,
  maxStackHeight: 0,
  ready: false,
});

/** 拖拽中的实时偏移（退场时从当前偏移续滑，对应 Swift withAnimation(exit)）。 */
const dragOffsets = new Map<string, number>();

/** 层叠态：未展开且多于一张。单张既非层叠也非展开（ToastStackView.piled）。 */
export function computePiled(): boolean {
  return !state.stackExpanded && state.presentations.length > 1;
}

function applyState(next: ToastState) {
  state.presentations = next.presentations;
  state.stackExpanded = next.stackExpanded;
  state.settings = next.settings;
  state.unreadCount = next.unreadCount;
  state.silenced = next.silenced;
  state.maxStackHeight = next.maxStackHeight;
  state.ready = true;
}

let unlisten: (() => void) | null = null;

export async function initStore() {
  if (unlisten) return;
  unlisten = await listen<ToastState>("toast://state", (event) => {
    applyState(event.payload);
  });
  try {
    const initial = await invoke<ToastState>("get_state");
    applyState(initial);
  } catch {
    // 首帧未就绪时保持默认值，事件会补上。
  }
}

export function disposeStore() {
  unlisten?.();
  unlisten = null;
}

export const toastStore = {
  state,
  computePiled,

  /** 层叠态下整块可见的卡片（Swift visibleCards：层叠只渲染最新一张）。 */
  visibleCards(): Presentation[] {
    return computePiled() ? state.presentations.slice(-1) : state.presentations;
  },

  /** 层叠时排在前排后面的卡片数（Swift behindCount）。 */
  behindCount(): number {
    return Math.max(0, state.presentations.length - 1);
  },

  setDragOffset(id: string, offset: number) {
    dragOffsets.set(id, offset);
  },
  dragOffset(id: string): number {
    return dragOffsets.get(id) ?? 0;
  },
  clearDragOffset(id: string) {
    dragOffsets.delete(id);
  },

  // ---- 交互意图 → Rust ----------------------------------------------------

  tap(id: string) {
    void invoke("tap_card", { id });
  },
  close(id: string) {
    void invoke("close_card", { id });
  },
  hover(id: string, hovering: boolean) {
    void invoke("set_hovering", { id, hovering });
  },
  setStackExpanded(expanded: boolean) {
    void invoke("set_stack_expanded", { expanded });
  },
  performAction(cardId: string, action: NotificationAction, comment?: string) {
    void invoke("perform_action", { cardId, action, comment: comment ?? null });
  },
  dragDismiss(id: string) {
    void invoke("drag_dismiss", { id });
  },
  remindLater(id: string, seconds: number) {
    void invoke("remind_later", { id, seconds });
  },

  // ---- 演示 / 静默 --------------------------------------------------------

  pushDemo() {
    void invoke("push_demo");
  },
  clearAll() {
    void invoke("clear_all");
  },
  silence(minutes = 60) {
    void invoke("silence", { minutes });
  },
  resumeSilence() {
    void invoke("resume_silence");
  },

  // ---- 原生材质面同步 ------------------------------------------------------

  reportFrames(frames: SurfaceFrame[]) {
    if (frames.length === 0) return;
    void invoke("report_frames", { frames });
  },
  reportContentHeight(height: number) {
    void invoke("report_content_height", { height });
  },
  borrowKey() {
    void invoke("borrow_key");
  },
  releaseKey() {
    void invoke("release_key");
  },
  openUrl(url: string) {
    void invoke("open_url", { url });
  },
};

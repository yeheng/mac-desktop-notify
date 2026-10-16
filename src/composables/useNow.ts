/**
 * Swift 的 TimelineView(.periodic(from: .now, by: 30))：收起态卡片的相对
 * 时间按慢时间轴老化，卡片在屏期间文字会从"刚刚"走到"5 分钟前"。
 */
import { onScopeDispose, ref } from "vue";

export function useNow(intervalMs = 30_000) {
  const now = ref(Date.now());
  const timer = window.setInterval(() => {
    now.value = Date.now();
  }, intervalMs);
  onScopeDispose(() => window.clearInterval(timer));
  return now;
}

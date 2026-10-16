/**
 * Swift `RelativeTime.describe(_:now:)` 的移植：收起态卡片头部的相对时间，
 * 用词与系统横幅一致。纯函数，边界可测。
 */
export function describe(dateMs: number, nowMs: number): string {
  const elapsed = (nowMs - dateMs) / 1000;
  // 时钟偏移造成的未来时间读作"刚刚"，永不为负。
  if (elapsed < 45) return "刚刚";
  if (elapsed < 3600) return `${Math.max(1, Math.floor(elapsed / 60))} 分钟前`;
  if (elapsed < 86400) return `${Math.floor(elapsed / 3600)} 小时前`;
  const date = new Date(dateMs);
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

/** 展开态头部的绝对时间：HH:mm（Swift `.dateTime.hour().minute()`）。 */
export function clockTime(dateMs: number): string {
  const date = new Date(dateMs);
  const hh = String(date.getHours()).padStart(2, "0");
  const mm = String(date.getMinutes()).padStart(2, "0");
  return `${hh}:${mm}`;
}

import { createApp } from "vue";
import App from "./App.vue";
import { initStore } from "@/stores/notifications";
import { initScriptHost } from "@/lib/scriptHost";
import "../style.css";

const app = createApp(App);
app.mount("#app");
void initStore();
// 脚本引擎宿主：backfill / hook / exec 三条路径的事件接线（引擎本体是
// 本 webview 的 TS，Rust 侧 script_host 只递请求、收回执）。
initScriptHost();

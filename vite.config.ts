import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

// Tauri 桌面应用的前端：dev server 固定端口，构建产物进 dist/。
export default defineConfig({
  plugins: [vue(), tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  // Vite 的默认清屏会吃掉 Rust 侧日志。
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
  },
  envPrefix: ["VITE_", "TAURI_ENV_*"],
  build: {
    target: "safari16",
    minify: false,
    sourcemap: false,
    // 每窗口一个 webview：toast 与 settings 各自的入口 HTML。
    rollupOptions: {
      input: {
        toast: path.resolve(__dirname, "toast.html"),
        settings: path.resolve(__dirname, "settings.html"),
      },
    },
  },
});

import { createApp } from "vue";
import App from "./App.vue";
import { initStore } from "@/stores/notifications";
import "../style.css";

const app = createApp(App);
app.mount("#app");
void initStore();

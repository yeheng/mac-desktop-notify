<script setup lang="ts">
/**
 * Swift MarkdownBlocksView 的逐块渲染：prose / heading / list / code 四种
 * 槽位，排版参数来自 MessageCards.NotificationBodyView（正文 13pt、代码
 * 等宽 13pt、标题 +2pt semibold、代码底 primary@8%）。
 *
 * 行内格式由 lib/markdown.ts 的 inlineHtml 产出（对应 Swift
 * AttributedString 的 inlineOnly 解析），先整体转义再替换。
 */
import { computed } from "vue";
import { segments, inlineHtml } from "@/lib/markdown";

const props = defineProps<{
  bodyMarkdown: string;
  fontSize?: number;
}>();

const blocks = computed(() => segments(props.bodyMarkdown));
</script>

<template>
  <div class="toast-md-body" :style="fontSize ? { '--toast-body-size': `${fontSize}px` } : undefined">
    <template v-for="(block, index) in blocks" :key="index">
      <p v-if="block.kind === 'prose'" class="md-prose" v-html="inlineHtml(block.lines.join('\n'))" />
      <p v-else-if="block.kind === 'heading'" class="md-heading" v-html="inlineHtml(block.text)" />
      <div v-else-if="block.kind === 'list'" class="md-list">
        <div v-for="(item, i) in block.items" :key="i" class="md-list-row">
          <span class="md-list-marker">{{ block.ordered ? `${i + 1}.` : "•" }}</span>
          <span class="md-list-text" v-html="inlineHtml(item)" />
        </div>
      </div>
      <pre v-else-if="block.kind === 'code'" class="md-code">{{ block.lines.join("\n") }}</pre>
    </template>
  </div>
</template>

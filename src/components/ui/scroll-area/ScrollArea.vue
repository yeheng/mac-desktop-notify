<script setup lang="ts">
import { cn } from "@/lib/utils";
import { ScrollAreaCorner, ScrollAreaRoot, ScrollAreaViewport } from "reka-ui";

const props = defineProps<{
  class?: string;
  /** 视口最大高度（展开态正文的滚动预算）。 */
  maxHeight?: string;
}>();
</script>

<template>
  <ScrollAreaRoot
    :class="cn('relative overflow-hidden', props.class)"
    type="hover"
  >
    <ScrollAreaViewport class="h-full w-full" :style="maxHeight ? { maxHeight } : undefined">
      <div class="min-h-0">
        <slot />
      </div>
    </ScrollAreaViewport>
    <ScrollAreaCorner />
  </ScrollAreaRoot>
</template>

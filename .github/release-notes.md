## 安装

1. 下载并解压 `MacDesktopNotify-*.zip`
2. 将 `MacDesktopNotify.app` 拖入 `/Applications`
3. 首次启动若提示「已损坏，无法打开」或「无法验证开发者」（本构建为 ad-hoc 签名，未加入 Apple 开发者计划），在终端执行一次：

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacDesktopNotify.app
   ```

> **系统要求**：macOS 14+（Apple Silicon）。Intel Mac 请参照 [README](https://github.com/yeheng/mac-desktop-notify#快速开始) 从源码构建。
>
> 完整功能说明与 URL Scheme / 本地 API / 脚本用法见 [README](https://github.com/yeheng/mac-desktop-notify)。

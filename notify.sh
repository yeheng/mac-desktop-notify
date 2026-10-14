SOCK="$HOME/Library/Application Support/MacDesktopNotify/api.sock"
# 1. 菜单栏点「静默 1 小时」，或把系统通知中心设为「每条都发」
curl -s --unix-socket "$SOCK" http://127.0.0.1/v1/status # 确认 silenced:true
# 2. 推送
curl -s --unix-socket "$SOCK" http://127.0.0.1/v1/push \
  -d '{"title":"触发测试","body":"静默中，应只进通知中心","urgency":"critical","native":true}'

# Pixiv 榜单卡片验证

Pixiv 榜单使用与推荐相同的瀑布卡片。榜单作者头像、作者入口、作品比例和页数已接入；封面右下角显示同款收藏爱心，触控区域为 48dp，封面圆角为 8dp。

榜单响应不带当前账号的收藏状态。首次点按只读取当前账号的作品详情，确认后再收藏或取消；读取失败、账号切换或请求过期时不会提交写操作。Pixiv 推荐解析遇到缺失或损坏的收藏状态也按未知处理。

## 验证

- 9 个 Pixiv / Explore 测试文件：149 passed、1 skipped、0 failed。
- `flutter analyze lib test`：无问题。
- `git diff --check`：通过。
- `flutter build apk --profile --target-platform android-arm64`：通过。
- `aapt dump badging`：包名 `lingxue.picakeep`，版本 `1.9.90` / code `7`，包含 `arm64-v8a`。
- 未安装 APK；未执行真实账号收藏写入。
- 真机视觉及在线收藏行为仍未验证。

## APK

- 文件：[app-after015-profile.apk](../../../build/verification/pixiv-ranking-card-015/app-after015-profile.apk)
- SHA256：`452B0CB9421809F8ABE8E1E878D3FB8054F3BDE0F7B843793A18A577F0CD63D9`
- 大小：71,912,498 bytes


# Pixiv 榜单瀑布流验证

本轮仅让探索页 Pixiv 来源的推荐和榜单使用瀑布卡片。榜单仍沿用自身榜期选择、分页请求、页尾状态和返回恢复；其它来源继续使用原列表布局。没有修改 011/013 内容，也没有安装 APK。

## 验证

- Explore/瀑布相关 6 个测试文件：78 passed、1 skipped、0 failed。
- `flutter analyze lib test`：无问题。
- `git diff --check`：通过。
- `flutter build apk --profile --target-platform android-arm64`：通过。
- 构建输入清单包含 780 个文件；构建前后无变化。

测试覆盖 Pixiv 榜期与续页、设置更新不触发请求、推荐/榜单与来源缓存隔离、详情返回恢复，以及六个非 Pixiv 来源保持列表。

## APK

- 文件：[app-after014-profile.apk](../../../build/verification/pixiv-ranking-014/app-after014-profile.apk)
- SHA256：`54E9B3665E960CA0311C0E69412252E37EC46D5F02CC5516FE5307BE2931F375`
- 大小：71,912,498 bytes
- 身份：`lingxue.picakeep`，version `1.9.90` / code `7`，ABI `arm64-v8a`
- 构建模式：profile；未安装。

机器可读结果见 [apk-metadata.json](apk-metadata.json) 和 [source-manifest.json](source-manifest.json)。本轮 011 调研文件未改动，构建前后 SHA256 均为 `476683E909C9DD57CEB54B782F3A4A1E54891EAFAEE4C38DA742D13894DEFDD1`。

实机滚动手感尚未验证。Pixiv 榜单解析器未提供宽高、作者头像/ID及权威书签状态，卡片使用默认比例与现有 fallback；收藏操作继续隐藏。

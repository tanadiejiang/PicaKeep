# 第59号回归修复验证

源码目录 `D:/Flutter_Projucts/PicaComic/PicaKeep`，main，保留前轮未提交变更。当前范围为数量、收藏档位定位、作者封面、本地瀑布流切换。未安装/卸载/清除用户数据。

## 原因与修改

1. 文件夹登记读取默认不计数，菜单将默认0当真实数量。现在按已加载插画快照一次统计，各目录匹配直接父目录；全部直接取快照总数（可能含其它下载根）。多页作品一件，跨目录副本各一件，搜索不改变目录总量。不新增逐子库同步COUNT。
2. 收藏工具栏档位位置变了，旧弹层仍固定top:72。现使用按钮坐标和Flutter弹出菜单安全区约束。
3. 作者缩略图自定义裁切URL改写遗漏custom-thumb目录。现路径和文件后缀配对转换；转换失败只尝试一次API原地址。加载有占位，失败有提示；真实图片比例保留。
4. 在线图片首响应失败之前流尚无人订阅，await close会永等，错误Future无法返回。现分别处理首响应错误/流传输错误，且共享请求只有创建者负责清除in-flight，避免后来的消费者提前移除产生重复HTTP请求。
5. 本地瀑布流切换集合后仍复用旧列位置。新增有序作品ID key，仅集合或顺序变化时重建布局，普通重建/补图保持渲染对象。旧实现删除首项后第二列首卡错误y=80已复现。

## 封面调研与GitHub参考

已阅读 `plan/Dco/docs/pixiv_油猴脚本功能整理.md`、`pixiv_网络与下载现状核查.md`、`pixiv_api_整理文档.md`，在三文末追加更正。原文“与我们的实现完全一致”漏掉了custom-thumb目录。

- [Pixiv Previewer convertThumbUrlToSmall](https://github.com/Ocrosoft/PixivPreviewer/blob/6142d3217d41f198c219bc8a763387cf4ab272e1/pixiv%20previewer.user.js)：custom-thumb→img-master与_custom→_master成对转换，540框。
- [PixEz 列表选图](https://github.com/Notsfsssf/pixez-flutter/blob/126bd52123c2f3cfc30b7d05a2f16c8a4ebfc8b0/lib/component/illust_card.dart)：按清晰度选medium/large/original。
- [PixEz 图片组件](https://github.com/Notsfsssf/pixez-flutter/blob/126bd52123c2f3cfc30b7d05a2f16c8a4ebfc8b0/lib/component/pixiv_image.dart)：缓存、加载与失败分别处理。

本项目作者页使用360框的保持比例缩略图（不是逐条原图），已带Referer/UA、有8连接池和解码宽度限制，缓存目录是应用内App.cachePath/online_images。360升级540提高精度，不等于加速。本次不盲目提高并发或修改全局超时。

后续可测量：cache.put逐次全目录trim的IO成本、视口外预取竞争、慢网首帧耗时；它们尚未被证明是截图空白根因。

## 验证边界

公开作者40892639/56627683接口与CDN在宿主直连超时，未取得用户手机请求状态，不能写成已实测404→200或已达到某速度。回归使用公开真实URL形状和模拟404/超时/流中断。截图单独不能证明作品比例错误。

自动化及构建结果在完成后补充。

## 自动化结果

- `full-test.txt`：2338通过、14跳过、0失败，137秒。
- `analyze.txt`：No issues found。
- `counts-e2e.txt`：真实SQLite与原页面的2→4→3菜单计数流程通过。
- 失败诊断属于测试事件循环等待，未给生产新增重复扫描；临时诊断代码已清理。
- `source-manifest.json`记录main HEAD及758个构建输入SHA256，工作树含前轮既有改动，不能视为纯59号差异。

## Profile包

构建成功，185秒。包：`build/verification/pixiv-regressions-59/app-after59-profile.apk`，SHA256 `EAE0D0E678E5480C968275C62A5EDD0201CEC2F6BEECA761BFEB913D87E8B5F7`。包名lingxue.picakeep，版本1.9.88+5，签名与前轮profile一致，三架构libapp.so哈希均已变化。仅构建，未安装。元数据在apk-metadata.json。

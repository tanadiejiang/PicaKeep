# PNG cold fit 热循环选优 · 2026-10-06

已采用 `opaque-row-skip`：仅当 libpng 元数据确认没有 alpha 通道、没有 tRNS 时，跳过源行中对每个像素 `alpha != 255` 的检查。此时 libpng 已填入 alpha=255，原循环对源像素没有写入；移除该遍历与原算法逐字节等价。AreaRescaler 仍缩放 RGBA 四通道，`finish()` 仍执行原 unpremultiply。没有改变 colour、EXIF、原像素 ROI、取消、内存准入或 backing 格式，不需要更换算法版本。

生产 `image_core.cpp` 冻结 SHA-256：`11a0063e451188e4d9852d403563b164b537b0ef104646d640a114007a6f5b07`。它与独立候选源文件逐字节相同。主任务此前构建的 reader512/1024 仍为旧 shared native `3f41c832…`，后续构建必须明确记录来源，不能用旧 APK 替新优化验收。

## 实际问题与候选边界

主任务 afterframe Redmi 同一 4096² PNG→384 的 cold 分项中，Flutter `getNextFrame` P95约245ms，先前32MiB阈值 native cold 总呈现约465ms。因此研究 quick PNG stream-fit 的逐像素转换和 area 工作量有依据；Windows native 单项改善不能证明 Redmi cold 呈现达标，也不能据此把封面阈值换回32MiB。

快路径只用于静态、非隔行、≤8-bit、无 ICC、orientation1、完整原区域且双轴缩小的 PNG，raw backing 必须不存在。本轮保留该条件和 libpng 转换。带 alpha 或 tRNS 的 RGB/灰度/调色板仍走原 premultiply；RGBA 即使恰好每个 alpha 都为255，也不会误判为元数据确定 opaque。1:1 走原像素路径，透明像素隐藏 RGB 不被改写。

| 候选 | 实现 | 极端缩小实证 | 决策 |
| --- | --- | --- | --- |
| baseline | 原 RGBA area + 原前后 alpha 转换 | 原行为 | 对照 |
| opaque-skip | opaque 源跳过 premultiply 和 finish 转换 | 4000×6000→2×2 与 baseline 不同 | 否决 |
| opaque-RGB3 | opaque 源保留 RGB，仅缩放3通道，输出原地扩展并填255 | 同一极端比例与 baseline 不同 | 否决 |
| opaque-row-skip | opaque 源只跳过无写入的逐像素检查，保留4通道与 finish | 所有已测普通/极端样本逐字节相同 | 已采用 |

4000×6000 uniform RGB(255,191,87)→2×2 的 baseline 首像素是 `[255,192,87,254]`，opaque-skip 是 `[254,191,87,254]`，RGB3 是 `[254,191,87,255]`。原因是现有 WebP 固定点 area 使常量255 alpha 舍入为254，随后原 unpremultiply 改变 RGB。8192²→2×3、640×60000→2×2、60000×640→2×2 也出现同类差异。不能因384封面全等而断言所有比例全等；被否决的实现和真实数据均保留。后续若研究 RGB3，须保留同一 alpha 舍入语义或独立版本化缩略算法，不能影响原像素缩放。

## 原生同条件 N30

Windows x64、MSVC19.50、Debug并启用现有/O2；显式复用同一批已构建的 pinned codec 静态库。独立项目输出 E盘，没有 Flutter build/run、手机操作或生产库替换。原文件直接读取封面 harness 同一 `identical-4k.png`，SHA-256 `11db732775cdb2497f108e0502ee4993e38b1e781231de81a7fca88e01361630`。每库3轮预热、30测量；每轮轮换库次序。cold 仅指 raw backing 始终不存在，OS/压缩文件缓存未清空；主任务 desktop 构建可能并行，报告保留每次测量，不声称独占系统或真正磁盘首次访问。

| 最终四库 N30 | Native P50 / P95 ms | Wall P50 / P95 ms | Working peak B | Disk B |
| --- | --- | --- | ---: | ---: |
| baseline | 137.977 / 145.124 | 137.997 / 145.157 | 701,114 | 0 |
| opaque-skip（否决） | 122.727 / 128.177 | 122.755 / 128.212 | 701,114 | 0 |
| opaque-RGB3（否决） | 109.455 / 116.110 | 109.473 / 116.148 | 685,752 | 0 |
| opaque-row-skip（采用） | 122.857 / 129.127 | 122.880 / 129.163 | 701,114 | 0 |

采用候选在此 native 实验 P50改善10.96%、P95改善11.02%，并不达到20%改善。初轮三库未含最终 row-skip，baseline146.169/168.201ms、opaque-skip129.371/136.993、RGB3 115.879/129.265；该历史结果保留，不拿跨轮 baseline 或被否决 RGB3 数字宣传最终收益。各库在4096²→384输出相同，但极端样本揭示其中两个候选不满足全比例一致。

## 质量、取消与预算

最终独立测试71组正常像素：RGB、灰度、1-bit灰度、1/2/4-bit调色板、palette+tRNS、gray+tRNS、alpha0/1/64/128/254/255、opaque RGBA、32个随机整数/非整数/近原尺寸缩小、16-bit、ICC、interlace；RGB/隐藏alpha另测整幅1:1并与原 PNG 解码像素严格相等。七组极端源/比例中最终候选全部逐字节匹配 baseline。source SHA、原输出SHA、结果峰值、backend均在 JSON。

四库1024B工作预算均返回3/null；提前取消、10ms后运行中取消均2/null，随后相同调用恢复成功且匹配原输出；没有 `.raw`/`.partial` 残留。最终候选重复既有 `verify_pixels.py`：22条成功解码记录，通过8方向、ICC sRGB、原alpha、tile seams、冷并发、取消、预算、source-version以及重复损坏输入释放回归。此处是 native 功能证据，Android RSS、GPU帧、reader生命周期和应用取消仍由主任务实测验收。

补验七组极端源/区域：每组1024B预算拒绝、提前取消、恢复原输出全通过；8192²、640×60000与60000×640另在实际解码10ms后取消，均2/null并恢复原输出，raw/partial仍0。独立证据 `native-png-row-skip-extreme-failures.json` SHA-256 `50c206d406397ec746fdc83a0f4141725b16e7f39b7923bfa4140802ffd1ab2b`，native源码/DLL不变。

## 证据与复跑

| 文件 | SHA-256 |
| --- | --- |
| `native-png-hotloop-initial-30.json` | `c2199398643e1d8c44795bec1172e6e1322cbcf5be60218363e903d1fe6c9eb7` |
| `native-png-hotloop-final-30.json` | `3060a81d2a444407ad46410aa739ea3ee02c8d26346271e7617463400f29f476` |
| `native-png-row-skip-quality.json` | `ba16d00aa4ba0fdfa4da54d6197c5b4b3cf835308f63371ae90e2e53449e7254` |
| 独立采用候选 Debug DLL | `26715432f7dab9880ebf4dcafe63812845c5817136ec71bc276684ec15b941a0` |

独立源、两个否决实现、采用 patch、Debug DLL 和任务合成 PNG 仍在 `E:/picakeep-native-022-artifacts/picakeep-png-hotloop-study`；大产物不加入项目。项目小证据另保留 `native-png-row-skip.patch`。研究脚本 `packages/picakeep_image_engine/native/tests/benchmark_png_hotloop.py` SHA-256 `aef35f970a49d1c2621df81d104bba73c503edb5225a735675eadab44d666006`，AST解析通过。它不编辑生产，prepare阶段要求旧baseline SHA精确匹配，以防拿现优化源码当baseline。

在项目根目录复跑现有独立四库（不覆盖实际应用）：

```powershell
python packages/picakeep_image_engine/native/tests/benchmark_png_hotloop.py run --build E:/picakeep-native-022-artifacts/picakeep-png-hotloop-study/build --cover E:/picakeep-image-pipeline-022-cover-profile/run-ddbe8d4e/identical-4k.png --fixtures E:/picakeep-image-pipeline-022-fixtures --output E:/picakeep-native-022-artifacts/picakeep-png-hotloop-study --samples 30 --warmup 3
```

重建独立四库时给已冻结旧 baseline copy，而非现 production：

```powershell
python packages/picakeep_image_engine/native/tests/benchmark_png_hotloop.py prepare --source E:/picakeep-native-022-artifacts/picakeep-png-hotloop-study/baseline.cpp --native-include D:/Flutter_Projucts/PicaComic/PicaKeep/packages/picakeep_image_engine/native/include --dependencies C:/Users/tanad/.codex/tmp/picakeep-native-022-build/windows --output E:/picakeep-native-022-artifacts/picakeep-png-hotloop-study
cmake -S E:/picakeep-native-022-artifacts/picakeep-png-hotloop-study -B E:/picakeep-native-022-artifacts/picakeep-png-hotloop-study/build -G "Visual Studio 18 2026" -A x64
cmake --build E:/picakeep-native-022-artifacts/picakeep-png-hotloop-study/build --config Debug --parallel 2
```

下一步应按最终native SHA重建profile并保留Redmi同封面、同384、同首帧定义、baseline/native候选N30；再测适屏与原1:1路径，检查内存旁路、输出/质量、取消/租约。封面阈值64MiB仍由应用实测决定，本轮没有改阈值。

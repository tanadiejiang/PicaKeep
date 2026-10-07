# Redmi 1024 tile 分项与 bounded viewport A/B · 2026-10-06

现有实测支持下一步比较单 viewport 原像素 ROI，而不是继续增大固定 tile。Android1024 single/continuous 产生和加载更多像素，UI image 创建与 PNG raster-cache 解码出现明显长尾；native 每块及 worker 排队远小于这些长尾。root已加入 defaultfalse 的 `viewportRegion` profile 候选，本调研只读分析，不改surface、native ABI或生产路线。

来源是 `reader-shared-{512,1024}-redmi-30.json`，两者均旧 shared native `3f41c832…`；新 PNG opaque-row-skip `11a0063e…` 不属于这两个报告。360样本/版本，errors0，真实raster定义保留。派生数据为 `native-reader-redmi-tile-stage-analysis.json`，SHA-256 `a479d3379e002fe85062164f5c28709f404af7296cc3f5b13ac8069f791ec3da`。

## 已有证据

| Android sharpFirst | 呈现 P95 ms | Native codec / worker wall 每记录 P95 ms | UI image creation P95 ms | Raster-cache PNG decode P95 ms |
| --- | ---: | --- | ---: | ---: |
| 512 single | 318.200 | 5.083 / 12.755 | 12.274 | 11.997 |
| 1024 single | 450.712 | 11.434 / 28.021 | 86.065 | 95.178 |
| 512 continuous | 361.115 | 5.971 / 13.824 | 14.844 | 13.397 |
| 1024 continuous | 615.062 | 12.995 / 33.223 | 129.619 | 149.786 |
| 512 double | 1390.679 | 6.725 / 15.325 | 13.858 | 41.670 |
| 1024 double | 386.430 | 12.225 / 33.909 | 31.621 | 138.059 |

double1024仍有sample0约1597.293ms、native单次1365.709ms初建；P95改善不能删除该真实初建。prepared single1024 P95为585.412ms、continuous623.612、double sharp358.278/preview535.557。prepared不代表raster cache不需要解码。这里各 stage P95是所有记录nearest-rank分位，呈现P95直接引用原summary；不同记录数量/并行相加不能证明精确关键路径。

1024 single sample1呈现468.282ms，12 native记录合计12,582,912输出像素，native codec加和51.429ms、UI creation加和275.911ms；continuous sample0呈现643.392ms，12 native记录，codec加和78.339ms、UI加和364.331ms。1024 single30轮 native+disk-hit共338,548,736像素，512为142,868,480，1024为2.37倍。native queue P95 single/continuous均约0.008ms，不能把明显长尾归给128队列或盲增workers。

profile每样本先从fit切到nativeScale并等待中心原像素完整，再pan到target并等待目标原像素完整。因此512常见30记录对应15+15 tile，1024的12记录对应6+6；这是两次完整画面而非同一最终viewport重复解码bug。A/B须保持两个等待、相同target/sourceRect、真实FrameTiming，不能只测最后单块native或删第一次等待。

sample0最终1:1源viewport为1080×1971.5约2.13MP。512 grid约15×512²=3.93MP，1024 grid约6×1024²=6.29MP；一个整数外扩viewport约1081×1972=2.13MP。减少FFI/image次数同时减少搬运和上传面积比单纯增大tile更合逻辑，但仍需真机实证，单个2.13MP image也可能触发更大上传长尾。

## 候选安全边界

root现候选已限定density=1，按原像素向外量化左上floor、右下ceil，再裁至原图范围；full-fit小层仍优先，远程RasterReaderPageSource和Flutter backend排除。源区域为整数，native output等于region尺寸，仍1:1原像素，使用现decodeRegion ABI。经只读建议，root已加入实际 `ReaderTileDemand.outputWidth * outputHeight`（ceil后的整数）≤4MP、单边≤16384，避免薄而很宽的ROI面积合格但native拒绝。

现native estimate按output字节和格式工作区预算，不依赖ROI x/y；稳定backing估算output+8条原宽缓存+32MiB。一个2.13MP ROI输出约8.52MB，在surface64MiB/global192MiB及现scheduler准入内；worker TTD、ImmutableBuffer、ui.Image过渡仍按现 `working + bytes*3`保守计入，不扩大全原图Flutter decode。

PNG局部区域的1:1不满足 quick_png 的缩小/全幅要求，cold时仍需完整lossless backing初建；viewport不能凭空消除96MP约384MB磁盘层或首建等待。旧grid原1:1也需初建，不能声称新candidate新增该成本。候选限定density=1且wholeFits优先不变，已隔离局部fit变量；仍保留fit和backingprepared分项，记录后端与ready状态。baseline JPEG的1:1 crop仍可走原quick JPEG；原低density边缘尺寸非IDCT整倍数时会安全fallback backing，勿强制改变坐标/缩放以制造快路径。

## 具体 A/B 与后续约束

第一轮维持512 grid default，viewportRegion=false/true在同一最终源码快照、同8000×12000源、同3布局/两模式、每组N30比较原ROI与prepared组；报告保留完整原首建和两次目标等待。必须核原sourceRect完整覆盖、1:1/hiddenalpha/ICC/方向/seams、fit低density与4000×6000 PNG/JPEG，记录实际请求面积、native/image次数、disk hit和FrameTiming。生产defaults保持原值，直到速度、质量、取消、原租约和OS内存一起有依据。

exact viewport矩形会随每一原像素pan改变cache key，重访可复用但拖动会产生大量近似重复PNG。若一次ROI获益但拖动差，下一受控候选可保留一个bounded viewport resident并加有限整数overscan及覆盖判据：仅当前visible被resident覆盖且同source/version/density时复用；一旦暴露新区域才换region。overscan不能超过4MP/单边16384，生成中保留旧画面与原取消/lease；不能每个pan请求全384MB原图。另可测2个竖向strip，每strip原宽×半viewport高约1.06MP，总面积仍2.13MP，可比较单大image上传长尾与两个中image并行，不改变像素密度。

PNG raster-cache持久写发生在postFrame后，但后台encoder仍可能和下一次visible upload/cache decode争用系统线程；stage无绝对起止或tileID，现数据不能定量归因。若viewport候选仍慢，后续另测persistRaster=false来隔离native warm路径与PNG cache成本，保留真实diskWarm及整体功能验证，不把关闭持久缓存冒充最终通用方案。

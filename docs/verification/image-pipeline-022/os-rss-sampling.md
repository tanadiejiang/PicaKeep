# 022 OS 内存旁路采样

`tools/image_pipeline_022_os_rss.py` 直接读取明确 PID 的 OS 内存计数，写入任务目录 JSONL。它不安装、启动、停止应用，不改手机/用户数据，不扫描图库。当前只验证采样能力，不能据此判定阅读器内存验收通过或存在泄漏。

Android 使用明确 `adb -s <device>` 与 `run-as lingxue.picakeep cat /proc/<pid>/stat /proc/<pid>/status /proc/<pid>/smaps_rollup /proc/<pid>/stat`。两端startTimeTicks必须一致，并与首样本一致，避免PID复用混入其它进程。profile包须允许run-as；设备SELinux拒绝、进程退出或缺status时保存error并停止，不写RSS=0。smaps_rollup不可读但status可读时保留status并标记rollup不可用。

Windows 使用只读process handle与 `GetProcessMemoryInfo`，保存创建时间FILETIME、WorkingSet64/PeakWorkingSet64及private commit；process handle固定目标，退出后停止，不重新寻找同名进程。API值与PowerShell Process对象对应同类OS计数。工具实测当前PowerShell以验证Windows路径，尚未拿该旁路做PicaKeep完整进出阅读验收。

## 使用

必须显式给 `--pid`、`--seconds`、绝对 `--task-root` 与 `--output`。duration支持1–3600秒，interval默认1秒（支持0.5–60秒）。输出不可覆盖已有证据，必须在包含picakeep名称的任务根目录内，拒绝link/reparse输出祖先。每样本flush；采样结束自动关闭句柄。Android最后一次读最多8秒timeout，因此总运行时长可能比指定duration多一个读取窗口，工具不会随后继续采样。

在项目根目录，读root刚启动后的实际PID，再明确传入工具；不要复制下面旧PID用于新一轮。示例为本次已实跑值：

```powershell
python tools/image_pipeline_022_os_rss.py --platform android --device 8021129d --pid 9710 --seconds 5 --interval 1 --task-root E:/picakeep-image-pipeline-022-work --output E:/picakeep-image-pipeline-022-work/os-rss-cover-redmi-first.jsonl
python tools/image_pipeline_022_os_rss.py --platform windows --pid 9476 --seconds 3 --interval 1 --task-root E:/picakeep-image-pipeline-022-work --output E:/picakeep-image-pipeline-022-work/os-rss-windows-powershell-calibration.jsonl
```

完整阅读进出复测由root协调：启动profile→只读获取实际PID→启动旁路采样（例如300秒）→照原60次生命周期流程→JSONL与harness UTC时间对齐。1秒轮询只能提供窗口内样本，不保证捕获瞬时峰值；VmHWM/PeakWorkingSet是进程存续的累计峰值，不能当每轮独立峰值。smaps遍历本身有采样开销，因此性能A/B需记录旁路启用状态。

## 已观察的结果

| Evidence | 实测 | Finding | Path |
| --- | --- | --- | --- |
| E-os-01：[os-rss-cover-redmi-first.jsonl](os-rss-cover-redmi-first.jsonl)，SHA256 `250ec5d3c6a3726ad6245f771c7e38b3aced70874c23c73de3329edc2765a5ed` | 2026-10-06 10:41:11–10:41:16（Asia/Singapore），Redmi/8021129d，coverprofile PID9710，5样本/0错误，同startticks95127321。status VmRSS253,353,984 B/VmHWM474,886,144 B；rollup RSS423,931,904 B/PSS331,633,664–331,645,952 B；每读125–141ms | F-os-android：run-as两来源均可读；status与rollup稳定不同，不能互换。该段没有同步Dart counter，不能把差值解释成Dart测错多少、泄漏多少或验收合格 | P-os-android：显式PID→stat身份→status快速RSS账目→smaps页表汇总→stat身份→JSONL |
| E-os-02：[os-rss-windows-powershell-calibration.jsonl](os-rss-windows-powershell-calibration.jsonl)，SHA256 `582559567a90231a0e882d05dbe9737e7b48366fe8059c4604ace1c688013bc7` | 同日10:42:03–10:42:06，PowerShell PID9476，3样本/0错误；WS68,829,184–69,603,328 B，peak69,193,728–69,603,328 B，创建时间固定 | F-os-windows：Windows只读counter路线可用，校准进程不是产品阅读器 | P-os-windows：OpenProcess只读→创建身份→GetProcessMemoryInfo→固定句柄→关闭 |
| E-os-03：[os-rss-windows-exited-target.jsonl](os-rss-windows-exited-target.jsonl)，SHA256 `6c07591ee235e3f3cc50df869974c43293e9da56b524a64eef4462d09894322f` | 前次看到的PicaKeep PID48140在采样前已退出，OpenProcess失败，0样本/1error，工具没有写0RSS或换别的进程 | F-os-closed：关闭目标明确失败，不误计成功。此前Get-Process只读值WS201,965,568/peak404,529,152 B仅为另时点观察 | P-os-closed：明确PID不存在→error终态→保留证据 |

旧 `reader-pool-redmi-full-30.json` 生命周期 afterExit 存在 `processCurrentRss=737280`（0.703MiB），另一些为几MiB，其最终为49,119,232B。旧报告没有同PID同时间的OS旁路采样，所以仅能判定这些Dart数值不足以支持RSS稳定/峰值验收，不能据不同entrypoint和不同时间的cover采样证明漏内存。该旧报告的resident/jobs/source leases/预算归零属于应用资源计数证据，仍须与旁路OS计数分开解释。

工具源SHA256 `a090a9496d8eb8354f1238215c9c27ca90c3299483129e00c29725ba1475764b`；用户时区依照Asia/Singapore，原JSONL保存UTC以供跨进程对齐。所有结果是观察记录，无passed/failed内存门槛自动判定。

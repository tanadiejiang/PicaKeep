/// 外观相关设置项常量与解析。
///
/// 字号设置 [appTextScaleSettingIndex]：解决不同系统的「字体大小/显示大小」
/// 差异导致 App 内文字忽大忽小的问题。默认锁定为 App 自身的标准字号（1.0），
/// 不再被系统字体缩放牵着走；用户可在「设置-外观」里手动选小/大/特大，或
/// 选「跟随系统」恢复旧行为。
const appTextScaleSettingIndex = 119;

/// 解析字号设置为有效的文字缩放系数。
///
/// 返回 `null` 表示「跟随系统」（不覆盖 MediaQuery 的 textScaler）；
/// 返回具体数值时，App 用该系数固定显示，屏蔽系统字体缩放差异。
double? resolveAppTextScale(String raw) {
  switch (raw.trim()) {
    case '0':
      return null; // 跟随系统
    case '1':
      return 0.9; // 小
    case '3':
      return 1.1; // 大
    case '4':
      return 1.25; // 特大
    case '2':
    default:
      return 1.0; // 标准（默认，锁定不随系统）
  }
}

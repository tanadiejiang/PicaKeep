/// 探索能力的纯 Dart 数据契约。
///
/// 本文件只允许依赖 `dart:` 与项目内同样是纯 Dart 的模型（[BaseComic]）。
/// **禁止**导入 Flutter、`ComicSource`、`Res`、任何网络单例或页面 —— 契约层要能
/// 在 `dart test` 下脱离 Flutter 运行，并作为后续 AI 工具的唯一数据入口。
library;

import 'package:picakeep/network/base_comic.dart';

/// 探索分区（推荐 / 榜单 / 分类）的能力枚举。
///
/// 源可以只声明其中一部分：未声明的分区在 UI 上直接不出现，而不是显示空页。
enum ExploreSectionKind {
  /// 推荐 / 最新 / 主页等"非榜单"内容块。
  recommend,

  /// 真实榜期榜单。榜期标签必须沿用站点自己的口径，不得改写（例如 EH 的
  /// 「昨天」不能叫今日）。
  ranking,

  /// 分类目录（原生分类或本地标签目录）。
  category,
}

/// 探索错误类型。
///
/// UI 与适配器都**按类型**决定呈现与重试策略，不靠猜测错误文案。只保留字符串
/// 的旧链路（`Res.errorMessage`）在转换为本类型时才允许退化为 [network]。
enum ExploreErrorCode {
  /// 需要登录（凭据缺失或明确被判定为未登录）。
  loginRequired,

  /// 已登录但无权访问（下架、年龄门槛、站点拒绝）。
  accessDenied,

  /// 网络层失败（连接、超时、DNS、5xx 等无法进一步归类的传输问题）。
  network,

  /// 响应到达但结构/字段无法解析。
  parse,

  /// 调用方给出的参数非法（未知源、空 ID、越界期号等）。
  invalidArgument,

  /// 该源不支持本次请求的入口 / 选项。
  unsupported,

  /// 续页句柄已过期（TTL 淘汰或会话释放）。
  expiredContinuation,
}

/// 一个结构化的探索失败。
///
/// 携带可展示文案与机器可判的类型；不携带凭据、Cookie 或完整内部 URL。
class ExploreError {
  const ExploreError(
    this.code,
    this.message, {
    this.statusCode,
  });

  final ExploreErrorCode code;
  final String message;

  /// 已知的 HTTP 状态码；未知时为空。
  final int? statusCode;

  bool get isLoginRequired => code == ExploreErrorCode.loginRequired;

  @override
  String toString() => 'ExploreError(${code.name}: $message)';
}

/// 一次探索请求的选项（0..n 个，源自行解释）。
///
/// 用列表而非 Map：源之间选项语义不同（期号 / 类型 / 语言 / 排序），且多数源
/// 在同一入口只用到一个单值选项。顺序即语义位次。
class ExploreOptions {
  const ExploreOptions([this._values = const <String>[]]);

  ExploreOptions.single(String value) : _values = <String>[value];

  static const ExploreOptions none = ExploreOptions();

  final List<String> _values;

  List<String> get values => List<String>.unmodifiable(_values);

  bool get isEmpty => _values.isEmpty;

  String? get first => _values.isEmpty ? null : _values.first;

  @override
  bool operator ==(Object other) {
    if (other is! ExploreOptions) return false;
    if (other._values.length != _values.length) return false;
    for (var i = 0; i < _values.length; i++) {
      if (other._values[i] != _values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_values);

  @override
  String toString() => 'ExploreOptions($_values)';
}

/// 一个可选条目（榜期 / 排序 / 类型）。
class ExploreOption {
  const ExploreOption({
    required this.id,
    required this.label,
  });

  /// 稳定 ID。裸值走本项目的契约（例如 NH 的 `popular-today`），不是站点 URL
  /// 片段；映射到真实参数由各源适配器负责。
  final String id;

  /// 界面展示文案。
  final String label;

  @override
  String toString() => 'ExploreOption($id, $label)';
}

/// 一个探索入口（例如「主页」「热门」「最新」「每周推荐」）。
class ExploreEntry {
  const ExploreEntry({
    required this.id,
    required this.label,
    required this.kind,
    this.options = const <ExploreOption>[],
    this.defaultOptionId,
    this.description = '',
    this.singlePage = false,
    this.supportsRefresh = true,
    this.availableAsTab = true,
    this.directoryAsTab = false,
  });

  final String id;
  final String label;
  final ExploreSectionKind kind;

  /// 该入口支持的选项；空列表表示无选项。
  final List<ExploreOption> options;

  /// 缺省选项 ID。**必须**是 [options] 中的一项（当 [options] 非空时）；
  /// 描述符构造时不做运行期校验，由 `ExploreRegistry` 与测试共同保证。
  final String? defaultOptionId;

  /// 入口说明（例如「榜单固定取自表站」）。
  final String description;

  /// 是否单页（无续页）：随机换一批、每周推荐内容等。
  final bool singlePage;

  /// 是否提供"手动刷新/换一批"语义。
  final bool supportsRefresh;

  /// 是否可作为该分区的**独立页签候选**。
  ///
  /// `false` 用于"只能由某个分区/概览的『更多』进入"的入口（例如 JM 的推荐块
  /// 更多、Pica 的集合详情）。这类入口没有独立的一级页签，把它们混进页签候选
  /// 会让 UI 出现无法直接使用的入口。
  ///
  /// 用显式标志而不是"按 id 猜"（曾经用 `endsWith('.more')` / `contains('Detail')`）：
  /// 猜法一旦有人改 id 就会静默失效，且无法被测试稳定覆盖。
  final bool availableAsTab;

  /// An entry such as weekly recommendations selects an issue before loading comics.
  final bool directoryAsTab;

  ExploreOption? optionById(String id) {
    for (final option in options) {
      if (option.id == id) return option;
    }
    return null;
  }

  String? get defaultOptionIdOrFirst {
    final declared = defaultOptionId;
    if (declared != null && optionById(declared) != null) {
      return declared;
    }
    return options.isEmpty ? null : options.first.id;
  }

  @override
  String toString() => 'ExploreEntry($id, $label)';
}

/// 一个源的探索能力描述。**不含** Widget / BuildContext / 凭据。
class ExploreSourceDescriptor {
  const ExploreSourceDescriptor({
    required this.sourceKey,
    required this.name,
    required this.entries,
    this.requiresLogin = true,
  });

  final String sourceKey;
  final String name;

  /// 该源声明的全部入口，按展示顺序。
  final List<ExploreEntry> entries;

  /// 该源探索是否需要登录。`true` 时未登录的源不发列表请求，只显示说明与
  /// 账号管理入口。
  final bool requiresLogin;

  List<ExploreEntry> entriesOf(ExploreSectionKind kind) =>
      entries.where((entry) => entry.kind == kind).toList(growable: false);

  ExploreEntry? entryById(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  @override
  String toString() =>
      'ExploreSourceDescriptor($sourceKey, ${entries.length} entries)';
}

/// 分类目录里的一项。
///
/// [route] 是结构化目标，**不是**页面拼出来的 `category:xxx@yyy` 字符串协议。
class ExploreCategoryItem {
  const ExploreCategoryItem({
    required this.id,
    required this.label,
    this.route,
    this.groupId = '',
    this.description = '',
    this.isSearch = false,
  });

  final String id;
  final String label;

  /// 该分类对应的结构化目标。`null` 表示只用于展示/分组，不可点击加载。
  final ExploreCategoryTarget? route;

  /// 所属分组 ID（原生分类的一级、标签目录的 namespace）。
  final String groupId;

  final String description;

  /// 是否为"具名搜索"语义（本地标签目录）。UI 需要与原生分类区分展示。
  final bool isSearch;

  @override
  String toString() => 'ExploreCategoryItem($id, $label)';
}

/// 分类目录里的一个分组。
class ExploreCategoryGroup {
  const ExploreCategoryGroup({
    required this.id,
    required this.title,
    required this.items,
    this.isSearch = false,
  });

  final String id;
  final String title;
  final List<ExploreCategoryItem> items;
  final bool isSearch;

  @override
  String toString() => 'ExploreCategoryGroup($id, ${items.length} items)';
}

/// 结构化分类目标。由各源适配器解释；UI 只负责透传。
class ExploreCategoryTarget {
  const ExploreCategoryTarget({
    required this.kind,
    required this.value,
    this.optionId,
    this.snapshotItems,
    this.contextKey,
  });

  /// 目标种类：`native`（原生分类）、`search`（具名搜索）、
  /// `special`（源内特殊集合，如 random/latest）。
  final String kind;

  /// 目标的稳定值（分类 slug / 原始分类名 / 查询词）。
  final String value;

  /// 该目标适用的排序选项 ID（可选）。
  final String? optionId;

  /// 无稳定 ID 的推荐集合由结果页持有不可变快照，不依赖父页会话缓存。
  final List<BaseComic>? snapshotItems;

  /// 内部上下文摘要；不得写入凭据。
  final String? contextKey;

  @override
  bool operator ==(Object other) =>
      other is ExploreCategoryTarget &&
      other.kind == kind &&
      other.value == value &&
      other.optionId == optionId;

  @override
  int get hashCode => Object.hash(kind, value, optionId);

  @override
  String toString() => 'ExploreCategoryTarget($kind, $value)';
}

/// 分类目录加载结果。
class ExploreDirectory {
  const ExploreDirectory({
    required this.sourceKey,
    required this.groups,
  });

  final String sourceKey;
  final List<ExploreCategoryGroup> groups;

  bool get isEmpty => groups.every((group) => group.items.isEmpty);
}

/// 概览里的一个分区。
class ExploreSection {
  const ExploreSection({
    required this.id,
    required this.title,
    required this.entryId,
    this.items = const <BaseComic>[],
    this.options = const <ExploreOption>[],
    this.selectedOptionId,
    this.moreEntryId,
    this.moreTarget,
    this.error,
    this.isSinglePage = false,
  });

  final String id;
  final String title;

  /// 该分区点击"更多"后加载的入口 ID。
  final String entryId;

  /// 已经加载好的条目（概览首屏）。
  final List<BaseComic> items;

  final List<ExploreOption> options;
  final String? selectedOptionId;

  /// 「查看更多」按钮目标的入口 ID；为空表示没有更多入口。
  final String? moreEntryId;

  /// 由 Provider 构造的真实目标；页面透传，不从分区标题猜分类或集合。
  final ExploreCategoryTarget? moreTarget;

  /// 该分区独立携带的错误：单个分区失败不影响其它分区。
  final ExploreError? error;

  final bool isSinglePage;

  ExploreSection copyWith({
    List<BaseComic>? items,
    String? selectedOptionId,
    ExploreError? error,
    bool clearError = false,
  }) {
    return ExploreSection(
      id: id,
      title: title,
      entryId: entryId,
      items: items ?? this.items,
      options: options,
      selectedOptionId: selectedOptionId ?? this.selectedOptionId,
      moreEntryId: moreEntryId,
      moreTarget: moreTarget,
      error: clearError ? null : (error ?? this.error),
      isSinglePage: isSinglePage,
    );
  }
}

/// 概览结果：若干个可独立成功/失败的分区。
class ExploreOverview {
  const ExploreOverview({
    required this.sourceKey,
    required this.entryId,
    required this.sections,
  });

  final String sourceKey;
  final String entryId;
  final List<ExploreSection> sections;

  bool get hasAnyContent => sections.any((section) => section.items.isNotEmpty);

  bool get allFailed =>
      sections.isNotEmpty && sections.every((section) => section.error != null);
}

/// 漫画页的分页描述。
class ExploreComicPage {
  const ExploreComicPage({
    required this.sourceKey,
    required this.entryId,
    required this.items,
    this.optionId,
    this.categoryId,
    this.nextToken,
    this.totalPages,
  });

  final String sourceKey;
  final String entryId;
  final List<BaseComic> items;
  final String? optionId;
  final String? categoryId;

  /// 续页句柄；`null` 表示没有下一页。
  ///
  /// 与 [hasMore] 严格一致：UI 不得靠"本页条数 == 页容量"之类的推断翻页。
  final String? nextToken;

  /// 站点明确给出的总页数（可选）。
  final int? totalPages;

  bool get hasMore => nextToken != null;

  bool get isSinglePage => nextToken == null;

  @override
  String toString() =>
      'ExploreComicPage($sourceKey/$entryId, ${items.length} items, '
      'hasMore: $hasMore)';
}

/// 加载结果的成功/失败两态。
sealed class ExploreResult<T> {
  const ExploreResult();

  ExploreError? get errorOrNull;

  bool get isSuccess => errorOrNull == null;

  T? get dataOrNull;
}

class ExploreSuccess<T> extends ExploreResult<T> {
  const ExploreSuccess(this.data);

  final T data;

  @override
  ExploreError? get errorOrNull => null;

  @override
  T? get dataOrNull => data;

  @override
  String toString() => 'ExploreSuccess($data)';
}

class ExploreFailure<T> extends ExploreResult<T> {
  const ExploreFailure(this.error);

  final ExploreError error;

  @override
  ExploreError? get errorOrNull => error;

  @override
  T? get dataOrNull => null;

  @override
  String toString() => 'ExploreFailure($error)';
}

/// 面向消费者会话的公开状态快照。
///
/// 只暴露"有哪些源、能不能用"，不暴露目录内容；目录与列表统一走 `load`。
class ExploreSourceState {
  const ExploreSourceState({
    required this.descriptor,
    required this.loggedIn,
  });

  final ExploreSourceDescriptor descriptor;
  final bool loggedIn;

  bool get usable => loggedIn || !descriptor.requiresLogin;
}

/// 一次加载请求。
///
/// [sessionId] + [continuation] 共同构成续页身份，Registry 用它校验句柄归属；
/// 页面刷新/销毁只释放自己的会话，不影响其它消费者（包括未来的 AI 工具）。
class ExploreRequest {
  const ExploreRequest({
    required this.sessionId,
    required this.sourceKey,
    required this.entryId,
    this.options = ExploreOptions.none,
    this.category,
    this.continuation,
    this.categoryId,
  });

  final String sessionId;
  final String sourceKey;
  final String entryId;
  final ExploreOptions options;

  /// 分类目标（分类页 / 分类目录点击）。
  final ExploreCategoryTarget? category;

  /// 续页句柄；首个请求必须为 `null`。
  final String? continuation;

  /// 分类目录项 ID，仅用于结果页展示与去重身份，不参与请求拼接。
  final String? categoryId;

  bool get isContinuation => continuation != null;

  ExploreRequest copyWith({
    String? entryId,
    ExploreOptions? options,
    ExploreCategoryTarget? category,
    bool clearCategory = false,
    String? continuation,
    bool clearContinuation = false,
    String? categoryId,
    bool clearCategoryId = false,
  }) {
    return ExploreRequest(
      sessionId: sessionId,
      sourceKey: sourceKey,
      entryId: entryId ?? this.entryId,
      options: options ?? this.options,
      category: clearCategory ? null : (category ?? this.category),
      continuation:
          clearContinuation ? null : (continuation ?? this.continuation),
      categoryId: clearCategoryId ? null : (categoryId ?? this.categoryId),
    );
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_prompt_tags.dart';

const aiPromptTemplatesSettingIndex = 132;
const aiPromptTagsLongTermSettingIndex = 136;
const aiPromptTemplatesInitializedSettingIndex = 137;

List<String> makeSettings({
  String templates = '[]',
  String initialized = '0',
  String longTerm = '0',
}) {
  final settings = List<String>.filled(
    aiPromptTemplatesInitializedSettingIndex + 1,
    '0',
  );
  settings[aiPromptTemplatesSettingIndex] = templates;
  settings[aiPromptTagsLongTermSettingIndex] = longTerm;
  settings[aiPromptTemplatesInitializedSettingIndex] = initialized;
  return settings;
}

void main() {
  group('默认标签与一次性初始化', () {
    test('包含计划规定的五个默认普通标签', () {
      expect(
        aiDefaultPromptTags.map((tag) => tag.name),
        <String>['搜角色', '搜题材', '搜标签', '不限来源', '结果不足重试'],
      );
      expect(aiDefaultPromptTags.every((tag) => tag.prompt.isNotEmpty), isTrue);
    });

    test('旧设置合法空数组首次初始化默认标签', () {
      final result = initializeAiPromptTagSettings(
        promptTemplatesJson: '[]',
        initializedValue: '0',
      );

      expect(result.promptTags, aiDefaultPromptTags);
      expect(result.initializedValue, '1');
      expect(result.installedDefaults, isTrue);
      expect(
          decodeAiPromptTags(result.promptTemplatesJson), aiDefaultPromptTags);
    });

    test('用户主动删空后不会再次自动补回', () {
      final result = initializeAiPromptTagSettings(
        promptTemplatesJson: '[]',
        initializedValue: '1',
      );

      expect(result.promptTags, isEmpty);
      expect(result.valuesChanged, isFalse);
      expect(result.installedDefaults, isFalse);
    });

    test('已有合法非空旧数据保持原始 JSON，仅补初始化标记', () {
      const raw = '{"旧标签":"旧提示"}';
      final result = initializeAiPromptTagSettings(
        promptTemplatesJson: raw,
        initializedValue: '0',
      );

      expect(result.promptTags, const <AiPromptTag>[
        AiPromptTag(name: '旧标签', prompt: '旧提示'),
      ]);
      expect(result.promptTemplatesJson, raw);
      expect(result.initializedValue, '1');
      expect(result.installedDefaults, isFalse);
    });

    test('损坏 JSON 不崩溃、不覆盖原文，只回退空列表', () {
      const raw = '{broken';
      final result = initializeAiPromptTagSettings(
        promptTemplatesJson: raw,
        initializedValue: '0',
      );

      expect(result.promptTags, isEmpty);
      expect(result.promptTemplatesJson, raw);
      expect(result.initializedValue, '1');
      expect(result.hasDecodeError, isTrue);
    });
  });

  group('JSON 与标签名校验', () {
    test('当前 JSON 格式可增删改并往返', () {
      const tags = <AiPromptTag>[
        AiPromptTag(name: '甲', prompt: '提示甲'),
        AiPromptTag(name: '乙', prompt: '提示乙'),
      ];

      final encoded = encodeAiPromptTags(tags);
      final decoded = decodeAiPromptTags(encoded);
      expect(decoded, tags);

      final edited = <AiPromptTag>[
        decoded.first.copyWith(prompt: '新提示'),
        const AiPromptTag(name: '丙', prompt: '提示丙'),
      ];
      expect(decodeAiPromptTags(encodeAiPromptTags(edited)), edited);
    });

    test('兼容包装格式和旧字段名', () {
      const raw = '{"tags":[{"title":"旧名","content":"旧内容"},'
          '{"label":"另一项","template":"模板"}]}';
      expect(decodeAiPromptTags(raw), const <AiPromptTag>[
        AiPromptTag(name: '旧名', prompt: '旧内容'),
        AiPromptTag(name: '另一项', prompt: '模板'),
      ]);
    });

    test('非法 JSON、重复名和固定来源保留名被拒绝', () {
      expect(() => decodeAiPromptTags('not-json'), throwsFormatException);
      expect(
        () => decodeAiPromptTags(
          '[{"name":"重复","prompt":"1"},'
          '{"name":"#重复","prompt":"2"}]',
        ),
        throwsFormatException,
      );
      expect(
        () => encodeAiPromptTags(const <AiPromptTag>[
          AiPromptTag(name: '搜jm', prompt: '不可覆盖协议'),
        ]),
        throwsFormatException,
      );
      expect(
        () => encodeAiPromptTags(const <AiPromptTag>[
          AiPromptTag(name: '搜本地', prompt: '不可覆盖协议'),
        ]),
        throwsFormatException,
      );
    });

    test('固定范围保留名 #搜本地 不能作为普通标签', () {
      expect(validateAiPromptTagName('搜本地'), isNotNull);
      expect(validateAiPromptTagName('#搜本地'), isNotNull);
    });

    test('名称会去掉一个前导井号并拒绝空白、换行和额外井号', () {
      expect(normalizeAiPromptTagName('  #标签  '), '标签');
      expect(validateAiPromptTagName(''), isNotNull);
      expect(validateAiPromptTagName('有 空格'), isNotNull);
      expect(validateAiPromptTagName('有\n换行'), isNotNull);
      expect(validateAiPromptTagName('##双井号'), isNotNull);
      expect(
        validateAiPromptTagName('重复', existingNames: const ['重复']),
        isNotNull,
      );
      expect(
        validateAiPromptTagName(
          '重复',
          existingNames: const ['重复'],
          originalName: '重复',
        ),
        isNull,
      );
    });
  });

  group('固定来源协议与解析', () {
    const ordinaryTags = <AiPromptTag>[
      AiPromptTag(name: '搜', prompt: '短提示'),
      AiPromptTag(name: '搜角色', prompt: '角色提示'),
      AiPromptTag(name: '不限来源', prompt: '恢复全部来源'),
    ];

    test('固定来源映射双向稳定', () {
      expect(sourceForAiPromptTagName('#搜pica'), 'picacg');
      expect(sourceForAiPromptTagName('搜jm'), 'jm');
      expect(sourceForAiPromptTagName('搜eh'), 'ehentai');
      expect(sourceForAiPromptTagName('搜nh'), 'nhentai');
      expect(aiPromptTagNameForSource('picacg'), '搜pica');
      expect(aiPromptTagNameForSource('unknown'), isNull);
    });

    test('多标签剥离、重复去重展开并保留未知 hashtag', () {
      final result = parseAiPromptTags(
        '#搜角色 #搜pica 请搜索 #未知\n#搜角色',
        promptTags: ordinaryTags,
      );

      expect(result.displayText, '#搜角色 #搜pica 请搜索 #未知\n#搜角色');
      expect(result.userText, '请搜索 #未知');
      expect(result.promptTags, const <AiPromptTag>[
        AiPromptTag(name: '搜角色', prompt: '角色提示'),
      ]);
      expect(result.sourceTags, <String>{'picacg'});
      expect(result.recognizedNames, <String>['搜角色', '搜pica']);
    });

    test('只有已识别标签时使用中性桥接 user 文本', () {
      final result = parseAiPromptTags(
        '#搜角色 #搜jm',
        promptTags: ordinaryTags,
      );
      expect(result.userText, aiPromptTagOnlyUserBridge);
      expect(result.displayText, '#搜角色 #搜jm');
    });

    test('多个来源标签映射为 source 值集合', () {
      final result = parseAiPromptTags('#搜pica #搜jm');
      expect(result.sourceTags, <String>{'picacg', 'jm'});
      expect(result.resetSourceRestriction, isFalse);
    });

    test('#不限来源和显式默认都会清空来源限制', () {
      final tagged = parseAiPromptTags(
        '#搜jm #不限来源 继续',
        promptTags: ordinaryTags,
      );
      expect(tagged.sourceTags, isEmpty);
      expect(tagged.resetSourceRestriction, isTrue);
      expect(tagged.userText, '继续');

      final explicit = parseAiPromptTags(
        '#搜jm 继续',
        resetSourceRestriction: true,
      );
      expect(explicit.sourceTags, isEmpty);
      expect(explicit.resetSourceRestriction, isTrue);
    });

    test('长名称优先且 token 边界不误删正文子串', () {
      final result = parseAiPromptTags(
        '#搜角色 #搜角色扩展 abc#搜 #搜，正文',
        promptTags: ordinaryTags,
      );

      expect(result.promptTags, const <AiPromptTag>[
        AiPromptTag(name: '搜角色', prompt: '角色提示'),
        AiPromptTag(name: '搜', prompt: '短提示'),
      ]);
      expect(result.userText, '#搜角色扩展 abc#搜 ，正文');
      expect(result.recognizedNames, <String>['搜角色', '搜']);
    });

    test('没有已识别标签时原样保留用户内容', () {
      const text = '正文 #未知 abc#搜角色';
      final result = parseAiPromptTags(text, promptTags: ordinaryTags);
      expect(result.userText, text);
      expect(result.recognizedNames, isEmpty);
      expect(result.promptTags, isEmpty);
    });

    test('未出现 #搜本地 时 localOnly 默认为 false', () {
      final result = parseAiPromptTags('#搜pica 继续', promptTags: ordinaryTags);
      expect(result.localOnly, isFalse);
    });

    test('识别 #搜本地 并置位 localOnly，同时剥离出 userText', () {
      final result = parseAiPromptTags('#搜本地 帮我找一下', promptTags: ordinaryTags);
      expect(result.localOnly, isTrue);
      expect(result.userText, '帮我找一下');
      expect(result.recognizedNames, <String>['搜本地']);
      expect(result.sourceTags, isEmpty);
    });

    test('#搜本地 与来源标签同时出现时二者互不清空，localOnly 优先由下游处理', () {
      final result = parseAiPromptTags(
        '#搜本地 #搜pica 继续',
        promptTags: ordinaryTags,
      );
      expect(result.localOnly, isTrue);
      expect(result.sourceTags, <String>{'picacg'});
      expect(result.recognizedNames, <String>['搜本地', '搜pica']);
    });

    test('#搜本地 不会被当作普通标签解析出 promptTags', () {
      final result = parseAiPromptTags('#搜本地', promptTags: ordinaryTags);
      expect(result.promptTags, isEmpty);
      expect(result.localOnly, isTrue);
    });

    // 15轮05号计划步骤 18-a：固定功能标签 #搜图。
    test('识别 #搜图 并置位 searchByImage，同时剥离出 userText', () {
      final result = parseAiPromptTags('#搜图 这是什么本子', promptTags: ordinaryTags);
      expect(result.searchByImage, isTrue);
      expect(result.recognizedNames, contains('搜图'));
      expect(result.userText, '这是什么本子');
    });

    test('未出现 #搜图 时 searchByImage 默认为 false', () {
      final result = parseAiPromptTags('#搜pica 继续', promptTags: ordinaryTags);
      expect(result.searchByImage, isFalse);
    });

    test('#搜图 与 #搜本地 同现时两标志各自成立', () {
      final result = parseAiPromptTags(
        '#搜图 #搜本地 帮我搜',
        promptTags: ordinaryTags,
      );
      expect(result.searchByImage, isTrue);
      expect(result.localOnly, isTrue);
      expect(result.recognizedNames, <String>['搜图', '搜本地']);
    });

    test('固定功能保留名 #搜图 不能作为普通标签（错误文案含「固定」）', () {
      expect(validateAiPromptTagName('搜图'), isNotNull);
      expect(validateAiPromptTagName('搜图'), contains('固定'));
      expect(validateAiPromptTagName('#搜图'), isNotNull);
    });
  });

  group('共享设置控制器', () {
    test('初始化、清空和重新创建控制器遵守一次性标记', () async {
      final settings = makeSettings();
      var persistCount = 0;
      final first = AiPromptTagSettingsController.detached(
        settings: settings,
        persistSettings: () => persistCount++,
      );

      await first.initialize();
      expect(first.tags, aiDefaultPromptTags);
      expect(settings[aiPromptTemplatesInitializedSettingIndex], '1');
      expect(persistCount, 1);

      await first.clearTags();
      expect(first.tags, isEmpty);
      expect(
          decodeAiPromptTags(settings[aiPromptTemplatesSettingIndex]), isEmpty);
      expect(persistCount, 2);

      final reopened = AiPromptTagSettingsController.detached(
        settings: settings,
        persistSettings: () => persistCount++,
      );
      await reopened.initialize();
      expect(reopened.tags, isEmpty);
      expect(persistCount, 2);
    });

    test('增改删、恢复默认和长期开关持久化并实时通知', () async {
      final settings = makeSettings(initialized: '1');
      var persistCount = 0;
      var notifyCount = 0;
      final controller = AiPromptTagSettingsController.detached(
        settings: settings,
        persistSettings: () => persistCount++,
      );
      await controller.initialize();
      controller.addListener(() => notifyCount++);

      await controller.addTag(const AiPromptTag(name: '新增', prompt: '一'));
      await controller.updateTag(
        '新增',
        const AiPromptTag(name: '改名', prompt: '二'),
      );
      await controller.setLongTermEnabled(true);
      await controller.removeTag('#改名');
      await controller.restoreDefaults();

      expect(controller.tags, aiDefaultPromptTags);
      expect(controller.longTermEnabled, isTrue);
      expect(settings[aiPromptTagsLongTermSettingIndex], '1');
      expect(
        decodeAiPromptTags(settings[aiPromptTemplatesSettingIndex]),
        aiDefaultPromptTags,
      );
      expect(persistCount, 5);
      expect(notifyCount, 5);
    });

    test('损坏 JSON 保留到用户恢复默认，并暴露错误状态', () async {
      const broken = '{broken';
      final settings = makeSettings(templates: broken);
      var persistCount = 0;
      final controller = AiPromptTagSettingsController.detached(
        settings: settings,
        persistSettings: () => persistCount++,
      );

      await controller.initialize();
      expect(controller.tags, isEmpty);
      expect(controller.hasInvalidStoredJson, isTrue);
      expect(settings[aiPromptTemplatesSettingIndex], broken);
      expect(persistCount, 1); // 只补 initialized 标记。

      await controller.restoreDefaults();
      expect(controller.hasInvalidStoredJson, isFalse);
      expect(controller.tags, aiDefaultPromptTags);
      expect(settings[aiPromptTemplatesSettingIndex], isNot(broken));
      expect(persistCount, 2);
    });
  });
}

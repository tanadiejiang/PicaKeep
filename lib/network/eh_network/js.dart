/// 从页面内联 JS 文本里按变量名抽取值（移植自上游 tools/js.dart）。
///
/// 用于从 ehentai 详情页内联脚本里提取 auth map（gid/token/apiuid/apikey/
/// showKey 等鉴权变量）。要求页面里的 JS 是合法的 `var name = value;` 形式。
Map<String, String> getVariablesFromJsCode(String html) {
  final variables = <String, String>{};

  final variableRegex = RegExp(r'var\s+(\w+)\s*=\s*(.*?);');
  final matches = variableRegex.allMatches(html);

  for (final match in matches) {
    final value = match.group(2)!;
    if (value.isNotEmpty && (value[0] == '"' || value[0] == "'")) {
      variables[match.group(1)!] = value.substring(1, value.length - 1);
    } else {
      variables[match.group(1)!] = value;
    }
  }
  return variables;
}

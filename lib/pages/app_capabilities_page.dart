import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/tools/translations.dart';

import 'settings/runtime_service_settings.dart';

class AppCapabilitiesPage extends StatelessWidget {
  const AppCapabilitiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom + 12;
    return Scaffold(
      appBar: AppBar(
        title: Text('APP能力'.tl),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPadding),
        children: buildAppCapabilitiesContent(context),
      ),
    );
  }
}

List<Widget> buildAppCapabilitiesContent(
  BuildContext context, {
  bool includeOverview = true,
}) {
  final children = <Widget>[];

  if (includeOverview) {
    children.add(
      _CapabilityOverviewCard(
        title: 'PicaKeep – 云端/NAS 一体化扩展'.tl,
        subtitle: '集中管理客户端 / 服务端运行能力，并保留后续扩展规划入口'.tl,
        status: '规划中'.tl,
      ),
    );
    children.add(const SizedBox(height: 12));
  }

  children.addAll([
    const AppServiceSettingsSection(),
    const SizedBox(height: 12),
    ListTile(
      leading: const Icon(Icons.pending_actions_outlined),
      title: Text('APP能力-未来规划'.tl),
      subtitle: Text('查看目标形态、技术骨架、阶段路线与后续规划'.tl),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AppCapabilityFuturePlanningPage(),
          ),
        );
      },
    ),
  ]);

  return children;
}

class AppCapabilityFuturePlanningPage extends StatelessWidget {
  const AppCapabilityFuturePlanningPage({super.key});

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom + 12;
    return Scaffold(
      appBar: AppBar(
        title: Text('APP能力-未来规划'.tl),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPadding),
        children: buildAppCapabilityFuturePlanningContent(context),
      ),
    );
  }
}

List<Widget> buildAppCapabilityFuturePlanningContent(BuildContext context) {
  final capabilities = serverPlatformCapabilityMatrix();
  return [
    _PlatformCapabilityMatrix(capabilities: capabilities),
    const SizedBox(height: 12),
    const _CapabilitySection(
      icon: Icons.flag_outlined,
      title: '当前状态',
      items: [
        '已完成本地漫画 / 已下载 / 本地图集 / 收藏 / 历史等本地阅读链路',
        '已建立 APP能力 集中入口，并将客户端 / 服务端运行能力配置归位到这里',
      ],
    ),
    const SizedBox(height: 12),
    const _CapabilitySection(
      icon: Icons.device_hub_outlined,
      title: '目标形态',
      items: [
        '客户端模式：手动输入服务端地址，后续支持局域网自动扫描与一键连接',
        '服务端模式：Windows / Linux / macOS 作为完整服务端目标，Android 作为移动增强服务端目标，统一直接读取本地数据库与图片文件，不依赖 SMB / NFS / FTP',
        '导航中增加服务信息面板，分别展示客户端连接状态或服务端运行状态',
      ],
    ),
    const SizedBox(height: 12),
    const _CapabilitySection(
      icon: Icons.developer_mode_outlined,
      title: '技术骨架',
      items: [
        '客户端与服务端共享数据模型、数据库访问逻辑与漫画元信息转换层',
        '局域网发现首选 mDNS / Bonjour，先避免自定义 UDP 广播对局域网其他设备产生额外噪声',
        '服务端使用纯 Dart + shelf，提供状态接口、漫画列表接口、图片流接口与后台管理入口',
        '通过 main_client.dart 与 main_server.dart 分离构建 Flutter 客户端与 Dart 服务端，并按桌面端 / Android 区分服务能力',
      ],
    ),
    const SizedBox(height: 12),
    const _CapabilitySection(
      icon: Icons.security_outlined,
      title: '基础约束',
      items: [
        '所有实际访问都走自研服务，默认不记录访问日志',
        '后台初版先保留登录页，但仅使用滑动成功即登录的占位方案，后续再替换为真实认证',
        '图片接口需要支持 Range 请求，保证大图与阅读翻页体验',
        '局域网无认证场景下仍需保留最小保护，例如只绑定内网、随机管理口令、可关闭自动发现',
      ],
    ),
    const SizedBox(height: 12),
    const _CapabilitySection(
      icon: Icons.timeline_outlined,
      title: '阶段路线',
      items: [
        '第一阶段：已补设置入口、工具入口与 APP能力 页面，并集中承载服务运行配置',
        '第二阶段：抽象 Local / Remote DataSource，打通客户端远程列表与详情接口',
        '第三阶段：补服务发现、管理后台，以及 Windows / Linux / macOS 服务端联调与部署',
        '第四阶段：补 Android 前台服务链路，并继续预留 Docker 化部署支持',
      ],
    ),
    const SizedBox(height: 12),
    const _CapabilitySection(
      icon: Icons.pending_actions_outlined,
      title: '后续会继续放在这里的内容',
      items: [
        '局域网自动扫描与一键连接体验',
        '真实认证与管理后台部署说明',
        '远程图集阅读与资源状态同步',
        '桌面端 / NAS / Android 服务端部署与保活细节',
      ],
    ),
  ];
}

class _PlatformCapabilityMatrix extends StatelessWidget {
  const _PlatformCapabilityMatrix({required this.capabilities});

  final List<ServerPlatformCapability> capabilities;

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_outlined),
                const SizedBox(width: 8),
                Text(
                  '平台能力矩阵'.tl,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < capabilities.length; index++) ...[
              _PlatformCapabilityRow(capability: capabilities[index]),
              if (index != capabilities.length - 1) const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlatformCapabilityRow extends StatelessWidget {
  const _PlatformCapabilityRow({required this.capability});

  final ServerPlatformCapability capability;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final chipBackgroundColor = capability.isFullServerTarget
        ? colorScheme.primaryContainer
        : capability.isEnhancedServerTarget
            ? colorScheme.secondaryContainer
            : colorScheme.surfaceContainerHighest;
    final chipForegroundColor = capability.isFullServerTarget
        ? colorScheme.onPrimaryContainer
        : capability.isEnhancedServerTarget
            ? colorScheme.onSecondaryContainer
            : colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              capability.displayName,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: chipBackgroundColor,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                serverPlatformTierLabel(capability.tier).tl,
                style: TextStyle(
                  color: chipForegroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('${capability.summary} ${capability.notes.first}'.tl),
      ],
    );
  }
}

class _CapabilityOverviewCard extends StatelessWidget {
  const _CapabilityOverviewCard({
    required this.title,
    required this.subtitle,
    required this.status,
  });

  final String title;
  final String subtitle;
  final String status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.cloud_sync_outlined),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(subtitle),
          ],
        ),
      ),
    );
  }
}

class _CapabilitySection extends StatelessWidget {
  const _CapabilitySection({
    required this.icon,
    required this.title,
    required this.items,
  });

  final IconData icon;
  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Text(
                  title.tl,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final item in items) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Icon(Icons.circle, size: 6),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(item.tl)),
                ],
              ),
              if (item != items.last) const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}

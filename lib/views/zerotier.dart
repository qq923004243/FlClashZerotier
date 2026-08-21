import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// FlClashTier: ZeroTier 网络设置页（独立栏目）。
///
/// 写入 `HomeDir/zerotier.json`（Go core 在 TUN 启动时读取；改动后重启 VPN 生效）。
/// 清空 network-id = 禁用 ZeroTier（纯 mihomo 模式，与 M0 行为一致）。
///
/// 私有 Planet（自建根服务器）：
/// - planet 文件保存到 `HomeDir/zerotier-planet.custom`；
/// - `zerotier.json` 增加 `"use-custom-planet": true`；
/// - Go core StartEngine 在创建 ZT 节点前把该文件装入 C wrapper，
///   ZT core 的 stateGet(PLANET) 将返回私有 planet 而非内置官方 planet。
class ZeroTierView extends ConsumerStatefulWidget {
  const ZeroTierView({super.key});

  @override
  ConsumerState<ZeroTierView> createState() => _ZeroTierViewState();
}

class _ZeroTierViewState extends ConsumerState<ZeroTierView> {
  /// Planet 文件头校验：world type 0x01 = planet（0x02 = moon）。
  static const int _planetMaxBytes = 8192;

  final _controller = TextEditingController();
  Timer? _debounce;
  String _status = '';

  bool _useCustomPlanet = false;
  int _planetFileSize = -1; // -1 = 未导入
  bool _planetBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  // ---- paths / config io ----

  Future<String> _homeDir() => appPath.homeDirPath;

  Future<File> _configFile() async {
    return File(p.join(await _homeDir(), 'zerotier.json'));
  }

  Future<File> _planetFile() async {
    return File(p.join(await _homeDir(), 'zerotier-planet.custom'));
  }

  Future<Map<String, dynamic>> _readConfig() async {
    try {
      final file = await _configFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic>) return json;
      }
    } catch (_) {
      // 文件缺失/损坏 → 视为空配置
    }
    return <String, dynamic>{};
  }

  /// 合并写回：保留未知字段，network-id 为空时移除该字段；
  /// 配置完全为空时才删除文件（Go core 将缺失文件解释为禁用 ZeroTier）。
  /// 注意：即使 network-id 暂时为空，也保留 use-custom-planet 等其余字段，
  /// 避免用户先导入 planet、后填 Network ID 时丢失开关状态。
  Future<void> _writeConfig(Map<String, dynamic> patch) async {
    final cfg = await _readConfig();
    cfg.addAll(patch);
    final nwid = (cfg['network-id'] as String?) ?? '';
    if (nwid.isEmpty) {
      cfg.remove('network-id');
    }
    final file = await _configFile();
    if (cfg.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString('${jsonEncode(cfg)}\n');
  }

  Future<void> _load() async {
    final cfg = await _readConfig();
    final nwid = ((cfg['network-id'] as String?) ?? '').trim();
    final planet = await _planetFile();
    _useCustomPlanet = (cfg['use-custom-planet'] as bool?) ?? false;
    _planetFileSize = await planet.exists() ? await planet.length() : -1;
    _controller.text = nwid;
    _status = nwid.isEmpty
        ? 'ZeroTier disabled (mihomo only)'
        : 'ZeroTier network: $nwid';
    if (mounted) setState(() {});
  }

  Future<void> _saveNwid(String value) async {
    final nwid = value.trim();
    // ZeroTier Network ID 必须是 16 位十六进制；非法值拒绝写入，避免
    // Go core StartEngine 解析失败后悄悄退回纯 mihomo 模式。
    final validNWID = RegExp(r'^[0-9a-fA-F]{16}$');
    if (nwid.isNotEmpty && !validNWID.hasMatch(nwid)) {
      setState(() {
        _status = '无效：Network ID 必须是 16 位十六进制（当前 ${nwid.length} 位），未保存';
      });
      return;
    }
    try {
      if (nwid.isEmpty) {
        await _writeConfig({'network-id': ''});
        _status = 'ZeroTier disabled (mihomo only)';
      } else {
        await _writeConfig({'network-id': nwid});
        _status = 'saved: $nwid — restart VPN to apply';
      }
      if (mounted) setState(() {});
    } catch (err) {
      _status = 'save failed: $err';
      if (mounted) setState(() {});
    }
  }

  // ---- private planet ----

  /// 校验 planet（world）文件：首字节 0x01 = planet，且不超过大小上限。
  String? _validatePlanet(Uint8List bytes) {
    if (bytes.isEmpty) return 'planet 文件为空';
    if (bytes.lengthInBytes > _planetMaxBytes) {
      return 'planet 文件过大（>$_planetMaxBytes 字节）';
    }
    if (bytes[0] != 0x01) {
      return '文件格式错误：首字节应为 0x01（planet），当前为 0x${bytes[0].toRadixString(16).padLeft(2, '0')}';
    }
    return null;
  }

  Future<void> _installPlanet(Uint8List bytes) async {
    final err = _validatePlanet(bytes);
    if (err != null) {
      throw err;
    }
    final file = await _planetFile();
    await file.safeWriteAsBytes(bytes);
    await _writeConfig({'use-custom-planet': true});
    _useCustomPlanet = true;
    _planetFileSize = bytes.lengthInBytes;
  }

  Future<void> _toggleCustomPlanet(bool value) async {
    if (!value) {
      await _writeConfig({'use-custom-planet': false});
      setState(() => _useCustomPlanet = false);
      return;
    }
    if (_planetFileSize < 0) {
      // 还没有 planet 文件：引导用户先导入。
      setState(() => _useCustomPlanet = false);
      globalState.showMessage(
        title: '私有 Planet',
        message: const TextSpan(
          text: '请先导入私有 planet 文件（文件导入 / URL 导入），再开启此开关。',
        ),
      );
      return;
    }
    await _writeConfig({'use-custom-planet': true});
    setState(() => _useCustomPlanet = true);
  }

  Future<void> _importPlanetFromFile() async {
    try {
      setState(() => _planetBusy = true);
      final platformFile = await picker.pickerFile();
      if (platformFile == null) return;
      final bytes = await platformFile.readBytes();
      await _installPlanet(bytes);
      if (!mounted) return;
      globalState.showMessage(
        title: '私有 Planet',
        message: TextSpan(
          text: '已导入 planet 文件（${bytes.lengthInBytes} 字节）。'
              '重启 VPN 后生效。',
        ),
      );
    } catch (e) {
      if (mounted) {
        globalState.showMessage(
          title: '私有 Planet',
          message: TextSpan(text: '导入失败：$e'),
        );
      }
    } finally {
      if (mounted) setState(() => _planetBusy = false);
    }
  }

  Future<void> _importPlanetFromUrl() async {
    final urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从 URL 导入 Planet'),
        content: TextField(
          controller: urlController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://example.com/planet',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.appLocalizations.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(urlController.text),
            child: Text(context.appLocalizations.confirm),
          ),
        ],
      ),
    );
    urlController.dispose();
    if (url == null || url.trim().isEmpty) return;

    try {
      setState(() => _planetBusy = true);
      // 走裸 dio（不经 clash 代理）：planet 通常托管在公网/内网直连可达处，
      // 且 VPN 未启动时也不应依赖代理链路。
      final response = await request.dio.get<Uint8List>(
        url.trim(),
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw '下载内容为空';
      }
      await _installPlanet(bytes);
      if (!mounted) return;
      globalState.showMessage(
        title: '私有 Planet',
        message: TextSpan(
          text: '已导入 planet 文件（${bytes.lengthInBytes} 字节）。'
              '重启 VPN 后生效。',
        ),
      );
    } catch (e) {
      if (mounted) {
        globalState.showMessage(
          title: '私有 Planet',
          message: TextSpan(text: '下载失败：$e'),
        );
      }
    } finally {
      if (mounted) setState(() => _planetBusy = false);
    }
  }

  Future<void> _removePlanet() async {
    final res = await globalState.showMessage(
      title: '私有 Planet',
      message: const TextSpan(
        text: '删除已导入的私有 planet 文件？删除后将自动切回官方 planet。',
      ),
    );
    if (res != true) return;
    try {
      final file = await _planetFile();
      await file.safeDelete();
      await _writeConfig({'use-custom-planet': false});
      setState(() {
        _planetFileSize = -1;
        _useCustomPlanet = false;
      });
    } catch (e) {
      if (mounted) {
        globalState.showMessage(
          title: '私有 Planet',
          message: TextSpan(text: '删除失败：$e'),
        );
      }
    }
  }

  // ---- ui ----

  String get _planetStatusText {
    if (_planetFileSize < 0) return '未导入（使用 ZeroTier 官方公共服务）';
    return '已导入（$_planetFileSize 字节）'
        '${_useCustomPlanet ? ' — 已启用，重启 VPN 生效' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BaseScaffold(
      title: 'ZeroTier',
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'ZeroTier 网络互联：配置 Network ID 后，命中 ZeroTier '
              'Managed Routes 的流量走 ZeroTier 内网，其余流量走 mihomo。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          ListTile(
            title: const Text('ZeroTier Network ID'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: '16 位十六进制 Network ID（留空 = 禁用）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  style: theme.textTheme.bodyMedium,
                  onChanged: (value) {
                    _debounce?.cancel();
                    _debounce = Timer(
                      const Duration(milliseconds: 800),
                      () => _saveNwid(value),
                    );
                  },
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _status,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '私有 Planet（自建 ZeroTier 根服务器）',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '默认连接 ZeroTier 官方公共 planet。如果你的网络部署在自建 '
              'planet（自托管 ztncui / ZeroTier 私有根）上，请在此导入你的 '
              'planet 文件并开启开关；否则节点将永远无法到达你的控制器。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          SwitchListTile(
            title: const Text('使用私有 Planet'),
            subtitle: Text(_planetStatusText),
            value: _useCustomPlanet,
            onChanged: _planetBusy ? null : _toggleCustomPlanet,
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('从文件导入 Planet'),
            enabled: !_planetBusy,
            onTap: _importPlanetFromFile,
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('从 URL 导入 Planet'),
            enabled: !_planetBusy,
            onTap: _importPlanetFromUrl,
          ),
          if (_planetFileSize >= 0)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除 Planet 文件'),
              enabled: !_planetBusy,
              onTap: _removePlanet,
            ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '使用步骤',
              style: theme.textTheme.titleSmall,
            ),
          ),
          const _StepText(
            '1. 先在「配置文件」页导入 Clash 配置（订阅链接/文件），'
            '此时首页才会出现启动 VPN 的按钮。',
          ),
          const _StepText(
            '2. 在本页填写 ZeroTier Network ID（可在 ZeroTier Central '
            '或你的自建控制器创建网络后获得）。',
          ),
          const _StepText(
            '3. 自建网络：导入你的私有 planet 文件并开启「使用私有 Planet」。',
          ),
          const _StepText(
            '4. 启动 VPN（首次会弹出系统授权），然后在控制器上授权本机节点。',
          ),
          const _StepText(
            '5. 修改 Network ID / Planet 后需重启 VPN 才生效；'
            '清空 Network ID 后为纯 mihomo 模式。',
          ),
        ],
      ),
    );
  }
}

class _StepText extends StatelessWidget {
  const _StepText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

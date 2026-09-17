import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v2ray_box/v2ray_box.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LightSpeedApp());
}

class LightSpeedApp extends StatelessWidget {
  const LightSpeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Light speed',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF7C4DFF),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final V2rayBox vpn = V2rayBox();
  final TextEditingController input = TextEditingController();

  StreamSubscription? statusSub;
  StreamSubscription? statsSub;

  VpnStatus status = VpnStatus.stopped;
  List<String> configs = <String>[];
  int selected = 0;
  String up = '0 B/s';
  String down = '0 B/s';
  String total = '0 B';
  String used = 'نامشخص';
  String remaining = 'نامشخص';
  String message = 'آماده اتصال';
  bool busy = false;
  bool isSubscription = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await vpn.initialize(notificationStopButtonText: 'قطع اتصال');
      await vpn.setCoreEngine('xray');
      await vpn.setServiceMode(VpnMode.vpn);

      final prefs = await SharedPreferences.getInstance();
      input.text = prefs.getString('last_input') ?? '';
      final savedConfigs = prefs.getStringList('configs') ?? <String>[];
      if (savedConfigs.isNotEmpty) {
        configs = savedConfigs;
      }

      statusSub = vpn.watchStatus().listen((value) {
        if (!mounted) return;
        setState(() {
          status = value;
          busy = value == VpnStatus.starting || value == VpnStatus.stopping;
          message = switch (value) {
            VpnStatus.started => 'متصل — ترافیک دستگاه از VPN عبور می‌کند',
            VpnStatus.starting => 'در حال ساخت تونل VPN...',
            VpnStatus.stopping => 'در حال قطع اتصال...',
            _ => 'قطع است',
          };
        });
      });

      statsSub = vpn.watchStats().listen((value) {
        if (!mounted) return;
        setState(() {
          up = value.formattedUplink;
          down = value.formattedDownlink;
          total = _formatBytes(value.uplinkTotal + value.downlinkTotal);
        });
      });
    } catch (e) {
      if (mounted) setState(() => message = 'خطای راه‌اندازی: $e');
    }
  }

  Future<void> _loadInput() async {
    final value = input.text.trim();
    if (value.isEmpty) {
      setState(() => message = 'لینک کانفیگ یا لینک سابسکریپشن را وارد کن');
      return;
    }

    setState(() => busy = true);
    try {
      if (_looksLikeSubscription(value)) {
        await _loadSubscription(value);
      } else {
        final error = await vpn.parseConfig(value, debug: true);
        if (error.isNotEmpty) throw Exception(error);
        configs = <String>[value];
        selected = 0;
        isSubscription = false;
        await _saveProfiles();
        setState(() => message = 'کانفیگ آماده اتصال است');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_input', value);
    } catch (e) {
      if (mounted) setState(() => message = 'خطای دریافت/خواندن: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loadSubscription(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw Exception('آدرس سابسکریپشن معتبر نیست');
    }

    final response = await http.get(
      uri,
      headers: const {'User-Agent': 'LightSpeed/7.0'},
    ).timeout(const Duration(seconds: 20));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }

    _readSubscriptionUserInfo(response.headers['subscription-userinfo']);

    final raw = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    final links = _extractLinks(raw);
    if (links.isEmpty) {
      throw Exception('هیچ کانفیگ VLESS/VMess/Trojan/SS در سابسکریپشن پیدا نشد');
    }

    final valid = <String>[];
    for (final link in links) {
      try {
        final error = await vpn.parseConfig(link);
        if (error.isEmpty) valid.add(link);
      } catch (_) {}
    }
    if (valid.isEmpty) throw Exception('کانفیگ‌های سابسکریپشن قابل استفاده نیستند');

    configs = valid;
    selected = 0;
    isSubscription = true;
    await _saveProfiles();
    if (mounted) {
      setState(() => message = '${valid.length} کانفیگ دریافت شد');
    }
  }

  List<String> _extractLinks(String raw) {
    final result = <String>[];
    final lines = raw.split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    void add(String value) {
      final v = value.trim();
      if (RegExp(r'^(vless|vmess|trojan|ss|hy2|hysteria|hy|tuic|wg|ssh)://',
              caseSensitive: false)
          .hasMatch(v) &&
          !result.contains(v)) {
        result.add(v);
      }
    }

    for (final line in lines) {
      add(line);
    }
    if (result.isNotEmpty) return result;

    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    try {
      final decoded = utf8.decode(base64Decode(base64.normalize(compact)));
      for (final line in decoded.split(RegExp(r'[\r\n]+'))) {
        add(line);
      }
    } catch (_) {}
    return result;
  }

  void _readSubscriptionUserInfo(String? header) {
    if (header == null || header.isEmpty) return;
    final values = <String, int>{};
    for (final part in header.split(';')) {
      final pieces = part.split('=');
      if (pieces.length == 2) {
        values[pieces[0].trim().toLowerCase()] = int.tryParse(pieces[1].trim()) ?? 0;
      }
    }
    final upload = values['upload'] ?? 0;
    final download = values['download'] ?? 0;
    final totalBytes = values['total'] ?? 0;
    final consumed = upload + download;
    final left = totalBytes > consumed ? totalBytes - consumed : 0;
    if (!mounted) return;
    setState(() {
      used = _formatBytes(consumed);
      remaining = totalBytes > 0 ? _formatBytes(left) : 'نامشخص';
    });
  }

  Future<void> _connect() async {
    if (configs.isEmpty) {
      await _loadInput();
      if (configs.isEmpty) return;
    }

    setState(() => busy = true);
    try {
      final permission = await vpn.checkVpnPermission();
      if (!permission) {
        final granted = await vpn.requestVpnPermission();
        if (!granted) throw Exception('مجوز VPN داده نشد');
      }

      final value = configs[selected];
      final error = await vpn.parseConfig(value, debug: true);
      if (error.isNotEmpty) throw Exception(error);

      final ok = await vpn.connect(value, name: 'Light speed');
      if (!ok) throw Exception('هسته VPN اتصال را قبول نکرد');
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          message = 'اتصال ناموفق: $e';
        });
      }
    }
  }

  Future<void> _connectFastest() async {
    if (configs.isEmpty) {
      await _loadInput();
      if (configs.isEmpty) return;
    }
    setState(() => busy = true);
    try {
      final results = await vpn.pingAll(configs, timeout: 7000);
      final usable = results.entries.where((e) => e.value >= 0).toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      if (usable.isEmpty) throw Exception('هیچ سروری پاسخ نداد');
      selected = configs.indexOf(usable.first.key);
      await _saveProfiles();
      if (mounted) setState(() => message = 'سریع‌ترین سرور: ${usable.first.value} ms');
      await _connect();
    } catch (e) {
      if (mounted) setState(() => message = 'خطای تست سرورها: $e');
    } finally {
      if (mounted && status != VpnStatus.started) setState(() => busy = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await vpn.disconnect();
    } catch (e) {
      if (mounted) setState(() => message = 'خطای قطع اتصال: $e');
    }
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('configs', configs);
    await prefs.setInt('selected', selected);
  }

  bool _looksLikeSubscription(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    return uri.isScheme('http') || uri.isScheme('https');
  }

  String _formatBytes(num bytes) {
    if (bytes < 1024) return '${bytes.toInt()} B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[i]}';
  }

  @override
  void dispose() {
    statusSub?.cancel();
    statsSub?.cancel();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = status == VpnStatus.started;
    return Scaffold(
      appBar: AppBar(title: const Text('Light speed ⚡')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Icon(connected ? Icons.shield : Icons.shield_outlined,
                      size: 72,
                      color: connected ? Colors.greenAccent : null),
                  const SizedBox(height: 8),
                  Text(connected ? 'VPN روشن است' : 'VPN خاموش است',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: busy ? null : (connected ? _disconnect : _connect),
                    icon: Icon(connected ? Icons.stop : Icons.power_settings_new),
                    label: Text(connected ? 'قطع اتصال' : 'اتصال'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: busy || connected ? null : _connectFastest,
                    icon: const Icon(Icons.speed),
                    label: const Text('تست همه و اتصال سریع‌ترین'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: input,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'کانفیگ یا لینک سابسکریپشن',
              hintText: 'https://... یا vless://...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: busy ? null : _loadInput,
            icon: const Icon(Icons.download),
            label: Text(isSubscription ? 'به‌روزرسانی سابسکریپشن' : 'خواندن / بررسی'),
          ),
          if (configs.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text('${configs.length} سرور'),
                    subtitle: Text('سرور انتخابی: ${selected + 1}'),
                    trailing: const Icon(Icons.dns),
                  ),
                  ...List.generate(configs.length, (index) {
                    final link = configs[index];
                    final name = _displayName(link, index);
                    return RadioListTile<int>(
                      value: index,
                      groupValue: selected,
                      onChanged: busy || connected
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => selected = value);
                              _saveProfiles();
                            },
                      title: Text(name),
                      subtitle: Text(link.split('://').first.toUpperCase()),
                    );
                  }),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _Stat(title: 'آپلود', value: up, icon: Icons.upload)),
            const SizedBox(width: 8),
            Expanded(child: _Stat(title: 'دانلود', value: down, icon: Icons.download)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _Stat(title: 'مصرف نشست', value: total, icon: Icons.data_usage)),
            const SizedBox(width: 8),
            Expanded(child: _Stat(title: 'باقی‌مانده ساب', value: remaining, icon: Icons.data_saver_on)),
          ]),
          if (used != 'نامشخص')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('مصرف سابسکریپشن: $used', textAlign: TextAlign.center),
            ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'مسیر ترافیک: برنامه‌های گوشی → Android VpnService/TUN → هسته Xray → سرور.\n'
                'وضعیت «متصل» فقط از وضعیت واقعی سرویس VPN گرفته می‌شود.',
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _displayName(String link, int index) {
    try {
      final uri = Uri.parse(link);
      final fragment = uri.fragment.trim();
      if (fragment.isNotEmpty) return Uri.decodeComponent(fragment);
      return '${index + 1}. ${uri.host}';
    } catch (_) {
      return 'سرور ${index + 1}';
    }
  }
}

class _Stat extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const _Stat({required this.title, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Icon(icon),
              const SizedBox(height: 6),
              Text(title),
              const SizedBox(height: 3),
              Text(value, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

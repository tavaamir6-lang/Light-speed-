import 'dart:async';
import 'package:flutter/material.dart';
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
  final TextEditingController link = TextEditingController();
  StreamSubscription? statusSub;
  StreamSubscription? statsSub;
  VpnStatus status = VpnStatus.stopped;
  String up = '0 B/s';
  String down = '0 B/s';
  String message = 'آماده اتصال';
  bool busy = false;

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
      link.text = prefs.getString('last_link') ?? '';
      statusSub = vpn.watchStatus().listen((value) {
        if (!mounted) return;
        setState(() {
          status = value;
          busy = value == VpnStatus.starting || value == VpnStatus.stopping;
          message = switch (value) {
            VpnStatus.started => 'متصل — ترافیک دستگاه از TUN عبور می‌کند',
            VpnStatus.starting => 'در حال ساخت تونل...',
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
        });
      });
    } catch (e) {
      if (mounted) setState(() => message = 'خطای راه‌اندازی: $e');
    }
  }

  Future<void> _connect() async {
    final value = link.text.trim();
    if (value.isEmpty) {
      setState(() => message = 'لینک کانفیگ را وارد کن');
      return;
    }
    setState(() => busy = true);
    try {
      final error = await vpn.parseConfig(value, debug: true);
      if (error.isNotEmpty) throw Exception(error);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_link', value);
      final permission = await vpn.checkVpnPermission();
      if (!permission) {
        final granted = await vpn.requestVpnPermission();
        if (!granted) throw Exception('مجوز VPN داده نشد');
      }
      final ok = await vpn.connect(value, name: 'Light speed');
      if (!ok) throw Exception('هسته VPN اتصال را قبول نکرد');
    } catch (e) {
      if (mounted) setState(() { busy = false; message = 'اتصال ناموفق: $e'; });
    }
  }

  Future<void> _disconnect() async {
    try {
      await vpn.disconnect();
    } catch (e) {
      if (mounted) setState(() => message = 'خطای قطع اتصال: $e');
    }
  }

  @override
  void dispose() {
    statusSub?.cancel();
    statsSub?.cancel();
    link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = status == VpnStatus.started;
    return Scaffold(
      appBar: AppBar(title: const Text('Light speed ⚡')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(connected ? Icons.shield : Icons.shield_outlined, size: 72,
                      color: connected ? Colors.greenAccent : null),
                  const SizedBox(height: 12),
                  Text(connected ? 'VPN روشن است' : 'VPN خاموش است',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: busy ? null : (connected ? _disconnect : _connect),
                    icon: Icon(connected ? Icons.stop : Icons.power_settings_new),
                    label: Text(connected ? 'قطع اتصال' : 'اتصال'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: link,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'VLESS / VMess / Trojan / SS',
              hintText: 'لینک کانفیگ را اینجا قرار بده',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _Stat(title: 'آپلود', value: up, icon: Icons.upload)),
            const SizedBox(width: 12),
            Expanded(child: _Stat(title: 'دانلود', value: down, icon: Icons.download)),
          ]),
          const SizedBox(height: 18),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'مسیر ترافیک: برنامه‌های گوشی → Android VpnService/TUN → هسته Xray → سرور.\n'
                'این صفحه تا زمانی که هسته واقعاً اتصال را تأیید نکند، وضعیت «متصل» را نمایش نمی‌دهد.',
              ),
            ),
          ),
        ],
      ),
    );
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
      padding: const EdgeInsets.all(16),
      child: Column(children: [Icon(icon), const SizedBox(height: 8), Text(title), const SizedBox(height: 4), Text(value)]),
    ),
  );
}

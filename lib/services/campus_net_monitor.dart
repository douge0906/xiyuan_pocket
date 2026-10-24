import 'dart:async';

import 'package:flutter/material.dart';

import 'campus_net_service.dart';

/// 校园网状态监控（2026-10-24）。
///
/// 解决「Wi-Fi 重连后卡片仍显示未连接」：
/// - 前台每 60 秒轻量探测一次
/// - 回到前台立即探测
/// - 页面可随时 `refresh(force: true)`
/// - 结果通过 [status] 广播，卡片订阅即可自动刷新
class CampusNetMonitor with WidgetsBindingObserver {
  CampusNetMonitor._();

  static final CampusNetMonitor instance = CampusNetMonitor._();

  final ValueNotifier<CampusNetStatus> status =
      ValueNotifier<CampusNetStatus>(CampusNetStatus.unknown);

  Timer? _timer;
  bool _probing = false;
  DateTime? _lastProbe;
  bool _started = false;

  static const Duration _interval = Duration(seconds: 60);
  static const Duration _minGap = Duration(seconds: 5);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    await refresh(force: true);
    _timer ??= Timer.periodic(_interval, (_) => refresh());
  }

  Future<void> refresh({bool force = false}) async {
    if (_probing) return;
    if (!force &&
        _lastProbe != null &&
        DateTime.now().difference(_lastProbe!) < _minGap) {
      return;
    }
    _probing = true;
    try {
      final s = await CampusNetService.detect();
      status.value = s;
      _lastProbe = DateTime.now();
    } catch (_) {
      // 探测失败保持上一次状态，避免闪成「未连接」
    } finally {
      _probing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh(force: true);
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }
}

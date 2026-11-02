import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音输入服务（2026-10-31）。
///
/// 封装 [SpeechToText]，把「开始听 → 拿到文本」包成一个干净的门面，
/// 页面只管调 [listen] 和监听回调。
///
/// 所有异常都吞掉并降级：语音识别不可用（设备没有识别服务、
/// 权限被拒、SDK 太老）时页面据此提示，而不是崩溃。
/// 语音识别初始化失败的原因（2026-10-31）。
///
/// ⚠️ 原来一律提示「本机暂不支持语音识别」，但实际最常见的原因是
///    **麦克风权限没给**（`speech_to_text` 只检查权限、不主动申请）——
///    两者被混为一谈，用户以为自己手机不支持。
enum InitFailure {
  /// 初始化成功。
  none,

  /// 用户拒绝了麦克风权限（或永久拒绝）。
  permissionDenied,

  /// 设备上没有可用的语音识别服务。
  noRecognizer,

  /// 其它异常。
  unknown,
}

class VoiceInputService {
  VoiceInputService._();

  static final VoiceInputService instance = VoiceInputService._();

  final SpeechToText _speech = SpeechToText();

  bool _initialized = false;

  /// 语音识别是否可用（设备有识别服务 + 已授权）。
  bool _available = false;

  bool get available => _available;

  InitFailure _failure = InitFailure.none;

  /// 最近一次初始化失败的原因。
  InitFailure get failure => _failure;

  // ── 一次 listen 会话的状态（2026-11-02 修「长按加号语音输入提示失败」）──
  //
  // 🔴 原实现只把 `onError` 拿去 `debugPrint`，`onStatus` 干脆丢弃，
  //    而 [listen] 的 `onDone` **只在初始化失败和抛异常时调用**，
  //    识别正常走完（无论有没有文字）时一次都不调用。
  //    于是上层 `HomePage._startVoiceInput` 里
  //    `while (recognized == null && error == null && ...)` 只能干等到
  //    **18 秒**超时，最后弹一句「没听清，请再试一次」——
  //    用户体感就是「语音输入总是失败，而且失败得很慢」。
  //
  //    现在把 error / done 两条底层信号接到 `onDone` 上，
  //    任何结局（有字、没字、报错）都会立刻落地。

  /// 本次会话是否已经回调过 [listen] 的 `onDone`。
  bool _finished = false;

  /// 本次会话是否已收到最终识别文本。
  bool _gotFinal = false;

  /// 上层注册的回调（本次会话有效）。
  void Function(String text)? _onFinal;
  void Function(String text)? _onPartial;
  void Function(double level)? _onLevel;
  void Function(String? error)? _onDone;

  /// 最近一次底层识别错误的可读文案（null = 没有错误）。
  String? _lastErrorText;

  /// 结束本次会话并回调 `onDone`（只生效一次）。
  void _finish(String? error) {
    if (_finished) return;
    _finished = true;
    _onDone?.call(error);
  }

  /// 底层识别错误 → 用户能看懂的一句话。
  ///
  /// 插件给的是 `error_no_match` / `error_network` 这类机器码，
  /// 直接弹给用户等于没解释。这里是**唯一**的映射点（R12）。
  static String describeError(String code) {
    final c = code.toLowerCase();
    if (c.contains('no_match')) return '没有听清，请再说一次';
    if (c.contains('speech_timeout')) return '没听到声音，请再说一次';
    if (c.contains('network')) return '语音识别需要联网，当前网络不可用';
    if (c.contains('audio')) return '麦克风被占用，请关掉其它录音应用后重试';
    if (c.contains('busy')) return '语音识别正忙，请稍后再试';
    if (c.contains('permission') || c.contains('insufficient')) {
      return '需要麦克风权限才能语音输入';
    }
    if (c.contains('client')) return '本机语音识别服务异常，请重启后重试';
    if (c.contains('server')) return '语音识别服务暂时不可用，请稍后重试';
    return '语音识别失败，请改用手动输入';
  }

  void _handleError(SpeechRecognitionError e) {
    final code = e.errorMsg;
    debugPrint('语音识别出错: $code');
    // 「没听到声音」这类不致命，等 status=done 一起收尾；
    // 其余错误直接结束，让上层立刻给出可读提示。
    if (code == 'error_no_match' || code == 'error_speech_timeout') {
      _lastErrorText = describeError(code);
      return;
    }
    _lastErrorText = describeError(code);
    _finish(_lastErrorText);
  }

  void _handleStatus(String status) {
    // `done` = 插件认为这一轮说完、结果全部交付；
    // `notListening` = 已停止收音。两者任一都可以收尾。
    if (status != SpeechToText.doneStatus &&
        status != SpeechToText.notListeningStatus) {
      return;
    }
    if (_gotFinal) {
      _finish(null); // 已经有最终文本，交给上层的 onFinal 处理
    } else {
      _finish(_lastErrorText ?? '没有听清，请再说一次');
    }
  }

  /// 请求麦克风权限。返回是否已授予。
  ///
  /// `speech_to_text` 的 `initialize` 只会**检查** RECORD_AUDIO，
  /// 不会替用户申请 → 没权限时直接返回 false，
  /// 于是被误报成「设备不支持语音识别」。这里先主动申请。
  Future<bool> requestMicrophone() async {
    if (!Platform.isAndroid && !Platform.isIOS) return true;
    try {
      final status = await Permission.microphone.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('申请麦克风权限失败: $e');
      return false;
    }
  }

  /// 初始化。返回是否可用。
  ///
  /// 🔴 只有**成功**才缓存结果（[ _initialized ]）。失败时保持未初始化，
  /// 下次再点语音会重新尝试 —— 否则一次瞬时失败（刚授完权限识别服务
  /// 还没起来、或 catch 到 PlatformException）会把本机语音锁死到
  /// 重启 App 为止。
  Future<bool> init() async {
    if (_initialized) return _available;
    try {
      _available = await _speech.initialize(
        onError: _handleError,
        onStatus: _handleStatus,
        debugLogging: false,
        // 🔴 关掉蓝牙权限申请（2026-11-02）。
        //
        // 插件默认会连同 `BLUETOOTH_CONNECT` 一起 `requestPermissions`，
        // 而本 App 的 AndroidManifest **没有声明**它 —— 申请一个未声明的
        // 权限并不会报错，只会被系统静默拒绝，白白多一次弹窗交互，
        // 极端 ROM 上还会让整次申请结果变成「部分授予」。
        // 本项目不支持蓝牙耳机收音，直接关掉最干净。
        options: <SpeechConfigOption>[SpeechToText.androidNoBluetooth],
      );
      if (_available) {
        _failure = InitFailure.none;
        _initialized = true;
      } else {
        // 初始化失败：再查一次麦克风权限，把「没权限」和
        // 「设备没有识别服务」区分开 —— 两者的解决办法完全不同。
        final mic = await Permission.microphone.status;
        _failure = mic.isGranted
            ? InitFailure.noRecognizer
            : InitFailure.permissionDenied;
      }
    } catch (e) {
      debugPrint('语音识别初始化失败: $e');
      _available = false;
      _failure = InitFailure.unknown;
    }
    return _available;
  }

  /// 开始听。
  ///
  /// - [onPartial] 实时中间结果（显示在语言球上）；
  /// - [onFinal] 最终结果（识别完成）；
  /// - [onLevel] 音量强度 0~1（驱动波纹）；
  /// - [onDone] 结束回调，参数是错误信息（null = 正常结束）。
  ///
  /// 返回 false 表示启动失败。
  Future<bool> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(double level) onLevel,
    required void Function(String? error) onDone,
  }) async {
    // 每次会话独立计状态，避免上一轮的 error/finished 污染这一轮。
    _finished = false;
    _gotFinal = false;
    _lastErrorText = null;
    _onPartial = onPartial;
    _onFinal = onFinal;
    _onLevel = onLevel;
    _onDone = onDone;
    if (!await init()) {
      // 按真实原因给文案 —— 一律说「设备不支持」会把「没给麦克风权限」
      // 的用户误导成「这台手机没有语音识别」。
      _finished = true; // 直接给结论，别再走一遍 _finish
      onDone(switch (_failure) {
        InitFailure.permissionDenied => '需要麦克风权限才能语音输入',
        InitFailure.noRecognizer => '本机没有可用的语音识别服务',
        _ => '语音识别启动失败，请改用手动输入',
      });
      return false;
    }
    try {
      await _speech.listen(
        // 这里统一读 [_onPartial] / [_onFinal] / [_onLevel]（而不是闭包参数）：
        // 会话状态的唯一来源就是这几个字段，`_handleStatus` / `_finish`
        // 也基于它们工作，两套来源容易漂移。
        onResult: (r) {
          if (r.recognizedWords.isEmpty) return;
          if (r.finalResult) {
            _gotFinal = true;
            _onFinal?.call(r.recognizedWords);
            // 部分机型 `done` 状态到得比 finalResult 还早，这里兜一手：
            // 拿到最终文本就当成功收尾（_finish 幂等）。
          } else {
            _onPartial?.call(r.recognizedWords);
          }
        },
        onSoundLevelChange: (level) {
          // 插件给的 dB 值大致在 -2 ~ 10 之间，映射到 0~1 驱动波纹。
          final v = ((level + 2) / 12).clamp(0.0, 1.0);
          _onLevel?.call(v);
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
          // 说完停顿 1.2 秒就出最终结果。
          pauseFor: const Duration(milliseconds: 1200),
          // 最长听 15 秒（用户可能想清楚措辞）。
          listenFor: const Duration(seconds: 15),
        ),
      );
      return true;
    } catch (e) {
      debugPrint('启动语音识别失败: $e');
      _finished = true;
      onDone('无法启动语音识别');
      return false;
    }
  }

  /// 停止听（出最终结果）。
  ///
  /// `stop()` 之后插件会推 `notListening`，正常情况下
  /// [_handleStatus] 已经收尾；这里再兜一次，保证上层不会卡在等待里。
  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {
      // 停止失败无需处理（下次 listen 会重新初始化）。
    }
    if (!_finished) {
      _finish(_gotFinal ? null : (_lastErrorText ?? '没有听清，请再说一次'));
    }
  }

  /// 取消听（用户中途退出）。
  ///
  /// 回调节点给 `null`：这是用户**主动**取消，不是失败，
  /// 上层不该再弹「没听清」这类错误提示。
  Future<void> cancel() async {
    try {
      await _speech.cancel();
    } catch (_) {}
    _finished = true; // 主动取消：不再触发 onDone，避免误报失败
  }
}

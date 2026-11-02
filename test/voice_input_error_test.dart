import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/services/voice_input_service.dart';

/// 回归：语音输入的错误**必须能变成人话**，而且是立刻，不是等 18 秒。
///
/// ## 用户报告的现象（2026-11-02）
///
/// 「长按加号语音输入提示失败」——具体表现是：长按 → 球出来 →
/// 说完之后**什么也没发生**，过很久才弹一句「没听清，请再试一次」。
///
/// ## 根因
///
/// `VoiceInputService.listen()` 的 `onDone` 只在「初始化失败」和
/// 「抛异常」两条路径被调用，**识别正常走完（无论有没有字）时一次都不调**。
/// 上层 `HomePage._startVoiceInput()` 里的
/// `while (recognized == null && error == null && now < deadline)` 只能干等
/// 18 秒超时。用户体感 = 又慢又失败。
///
/// 修复后底层 `onError` / `onStatus` 都接到 `onDone`：
/// 任何结局都会立刻落地。这份测试锁的是**错误码到文案的映射**，
/// 以及几个容易退化的边界。
void main() {
  group('describeError：错误码必须是用户能看懂的一句话', () {
    test('没听清 / 超时 —— 提示再说一次，而不是「失败」', () {
      expect(VoiceInputService.describeError('error_no_match'),
          contains('再说一次'));
      expect(VoiceInputService.describeError('error_speech_timeout'),
          contains('再说一次'));
    });

    test('网络问题要说明是联网需求，不是设备坏了', () {
      final msg = VoiceInputService.describeError('error_network');
      expect(msg, contains('联网'));
      expect(msg, isNot(contains('设备')));
    });

    test('网络超时也归类到网络，而不是「未知错误」', () {
      expect(VoiceInputService.describeError('error_network_timeout'),
          contains('联网'));
    });

    test('麦克风被占用时给出可操作的解决办法', () {
      final msg = VoiceInputService.describeError('error_audio_error');
      expect(msg, contains('麦克风'));
      expect(msg, contains('占用'));
    });

    test('正在被别的会话占用（busy）要说「稍后再试」', () {
      expect(VoiceInputService.describeError('error_busy'), contains('稍后'));
    });

    test('权限类错误指向权限，而不是让用户以为手机不支持', () {
      final msg = VoiceInputService.describeError('error_insufficient_permissions');
      expect(msg, contains('权限'));
    });

    test('🔴 任何未知错误码都要有兜底文案，不能返回空串', () {
      for (final code in const [
        '',
        'error_client',
        'error_server',
        'completely_unknown_code',
        'ERROR_BUSY', // 大小写不敏感
      ]) {
        expect(VoiceInputService.describeError(code), isNotEmpty,
            reason: '错误码 "$code" 必须有可读文案');
      }
    });

    test('大小写不敏感（插件可能给全大写）', () {
      expect(VoiceInputService.describeError('ERROR_NO_MATCH'),
          VoiceInputService.describeError('error_no_match'));
    });
  });
}

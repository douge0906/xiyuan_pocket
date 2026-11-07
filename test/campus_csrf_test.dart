import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/campus_session.dart';

/// `csrftoken` 提取的回归测试。
///
/// 背景：教务页面给的是 `<uuid>,<uuid去横线>` 这种两段式，业务接口只认逗号前
/// 那一段。这个逻辑原本分散在 `course_fetcher` / `jwgl_client` / `study_client`
/// 三处，**只有 `study_client` 做了 `split(',')`**，另外两处原样返回 →
/// 成绩 / 考试 / 教材 / 课表四类查询都会拿到带逗号的令牌。
/// 现在统一走 [extractCsrfToken]，这份测试钉住它的行为，防止再分叉。
void main() {
  group('extractCsrfToken', () {
    test('两段式令牌只取逗号前那一段', () {
      const html =
          '<input type="hidden" id="csrftoken" value="4F1A2B3C-1111-2222,4F1A2B3C11112222" />';
      expect(extractCsrfToken(html), '4F1A2B3C-1111-2222');
    });

    test('只有一段时原样返回', () {
      const html = '<input id="csrftoken" value="SINGLE-TOKEN" />';
      expect(extractCsrfToken(html), 'SINGLE-TOKEN');
    });

    test('属性顺序反转（value 在 id 之前）取不到 → 返回空串，不返回半截', () {
      const html = '<input value="ABC,DEF" id="csrftoken">';
      // 正则要求 id 在 value 之前。这个顺序教务未出现过，钉住「取不到就返回
      // 空串」而不是抛异常或返回带逗号的半截令牌 —— 调用方据此走 csrf 可选分支。
      expect(extractCsrfToken(html), '');
    });

    test('页面上没有 csrftoken 时返回空串，不抛异常', () {
      // 2026-11-02 抓的真实学业页（581,116 字符）就是这种形态：
      // 有 treeview、有课程数据，但 `csrftoken` 命中为 0。
      const html = '<html><body><ul class="treeview" id="ul1"></ul></body></html>';
      expect(extractCsrfToken(html), '');
    });

    test('逗号后面有空格时也要 trim', () {
      const html = '<input id="csrftoken" value="AAA , BBB">';
      expect(extractCsrfToken(html), 'AAA');
    });
  });
}

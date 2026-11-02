/// 待办自然语言解析（2026-10-31）。
///
/// 把「明天下午3点交高数作业」这类口语解析成
/// **日期 + 时分 + 干净的标题**。
///
/// 抽成独立文件是为了**一处实现两处用**：
///   · [AddTodoDialog] —— 用户在标题框里直接打自然语言；
///   · 语音输入 —— 识别结果同样走这套解析。
///
/// 两边各写一套解析迟早会漂（语音能听懂「下周一」，手打却不行），
/// 所以共用同一份实现。
class TodoNaturalParser {
  TodoNaturalParser._();

  /// 解析结果。
  ///
  /// - [day] 解析出的日期（null = 没提到日期）；
  /// - [hour]/[minute] 解析出的时分（null = 没提到时间）；
  /// - [clean] 去掉时间描述后的**干净标题**。
  static ({DateTime? day, int? hour, int? minute, String clean}) parse(
    String input, {
    DateTime? base,
  }) {
    var text = input.trim();
    DateTime? day;
    int? hour;
    int? minute;
    // ⚠️ base 之前声明了却没用（永远取 DateTime.now()），单测想注入
    //    「假今天」就会失灵 —— 这里真的用上它。
    final now = base ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    void consume(RegExp re, void Function(RegExpMatch m) apply) {
      final m = re.firstMatch(text);
      if (m == null) return;
      apply(m);
      text = text.replaceRange(m.start, m.end, ' ').trim();
    }

    // 今天 / 明天 / 后天
    consume(RegExp(r'(今天|明天|后天|大后天)'), (m) {
      final days = switch (m.group(1)) {
        '今天' => 0,
        '明天' => 1,
        '后天' => 2,
        _ => 3,
      };
      day = today.add(Duration(days: days));
    });

    // 周X / 下周X / 下下周X
    consume(RegExp(r'(下下|下)?周([一二三四五六日天])'), (m) {
      const map = {
        '一': 1,
        '二': 2,
        '三': 3,
        '四': 4,
        '五': 5,
        '六': 6,
        '日': 7,
        '天': 7
      };
      final target = map[m.group(2)]!;
      var delta = (target - today.weekday + 7) % 7;
      // 「下周X」= 本周X + 7 天；「下下周X」= + 14 天。
      if (m.group(1) == '下') delta += 7;
      if (m.group(1) == '下下') delta += 14;
      day = today.add(Duration(days: delta));
    });

    // X月X日（补「日」可选）
    consume(RegExp(r'(\d{1,2})月(\d{1,2})日?'), (m) {
      final mo = int.parse(m.group(1)!);
      final d = int.parse(m.group(2)!);
      // 月份非法时忽略这段，不让整句话解析失败。
      if (mo < 1 || mo > 12 || d < 1 || d > 31) return;
      // 🔴 「2月31日」不能静默溢出成 3 月 3 日：用 DateTime 归一化后回读，
      //    对不上就说明这天的确不存在，直接放弃这段解析。
      final probe = DateTime(now.year, mo, d);
      if (probe.month != mo || probe.day != d) return;
      day = probe;
    });

    // 上午 / 早上 / 下午 / 晚上 / 中午（要先记下来，供小时数换算）。
    //
    // ⚠️ 必须带上「今晚 / 明早 / 明晚」这类**组合词**：
    //    语音输入里「今晚8点」「明早9点」极常见，
    //    只认单字「晚上」会漏掉 → 8 点被当成早上 8 点。
    final period = RegExp(
            r'(上午|早上|早晨|下午|晚上|夜里|中午|傍晚|今晚|明早|明晚|今早|明晚)'
            )
        .firstMatch(text)
        ?.group(1);

    // 15:30 / 15：30
    consume(RegExp(r'(\d{1,2})[:：](\d{2})'), (m) {
      hour = int.parse(m.group(1)!);
      minute = int.parse(m.group(2)!);
    });

    // 3点 / 3点半 / 3点20分
    consume(RegExp(r'(\d{1,2})点(半|(\d{1,2})分?)?'), (m) {
      hour ??= int.parse(m.group(1)!);
      minute ??= m.group(2) == '半' ? 30 : int.tryParse(m.group(3) ?? '') ?? 0;
    });

    // 三点 / 十点半 / 二十三点（2026-11-01 补：此前只认阿拉伯数字，
    //   与上面的「周([一二三四五六日天])」口径不一致 —— 语音说「三点交作业」
    //   解析不出时间）。
    //
    //   ⚠️ 只在该短语**处于句首或标点/空格之后**时才匹配：
    //     「检查三点」里的「三点」是正文，不该被当成 3 点吃掉。
    final cnTime = RegExp(
      r'([一二两三四五六七八九十]{1,2})点(半|([一二三四五六七八九十\d]{1,2})分?)?',
    ).firstMatch(text);
    if (cnTime != null) {
      final before = cnTime.start == 0 ? '' : text[cnTime.start - 1];
      final atBoundary = before.isEmpty || '，,。；;：: '.contains(before);
      final h = atBoundary ? _cnNumber(cnTime.group(1)!) : null;
      if (h != null && h >= 0 && h <= 23) {
        hour ??= h;
        if (cnTime.group(2) == '半') {
          minute ??= 30;
        } else if (cnTime.group(3) != null) {
          minute ??= int.tryParse(cnTime.group(3)!) ??
              _cnNumber(cnTime.group(3)!) ??
              0;
        } else {
          minute ??= 0;
        }
        text = text.replaceRange(cnTime.start, cnTime.end, ' ').trim();
      }
    }

    if (hour != null) {
      // 「下午3点」→ 15 点。语音识别常把「下午」漏掉，这里只做
      // 明确有 period 时的换算，不猜。
      final isPm = period == '下午' ||
          period == '晚上' ||
          period == '傍晚' ||
          period == '今晚' ||
          period == '明晚' ||
          period == '夜里';
      final isAm = period == '上午' ||
          period == '早上' ||
          period == '早晨' ||
          period == '今早' ||
          period == '明早';
      if (isPm && hour! < 12) {
        hour = hour! + 12;
      }
      // 「上午9点」在下午说的时候其实是下午 —— 但我们不猜，
      // 只有明确说了「上午/早上」才按上午处理（保持 9 点）。
      if (isAm && hour! == 12) hour = 0;
      if (period == '中午' && hour! < 11) hour = hour! + 12;
      hour = hour!.clamp(0, 23);
      if (minute != null) minute = minute!.clamp(0, 59);
    }

    // 清掉时段词与虚词，得到干净标题。
    text = text.replaceFirst(
        RegExp(r'(上午|早上|早晨|下午|晚上|夜里|中午|傍晚|今晚|明早|明晚|今早)'),
        ' ');
    text = text
        .replaceAll(RegExp(r'^(在|于|要|得|需要|记得|提醒我)\s*'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'^[，,。.、；;：:\s]+|[，,。.、；;：:\s]+$'), '');

    return (day: day, hour: hour, minute: minute, clean: text);
  }

  /// 中文数字 → int（0–23 够用：「三点」「十点半」「二十三点」）。
  /// 无法解析时返回 null，调用方必须判空后放弃该段。
  static int? _cnNumber(String s) {
    const digits = <String, int>{
      '零': 0, '〇': 0, '一': 1, '两': 2, '二': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    };
    if (s.isEmpty) return null;
    if (s.length == 1) return digits[s];
    final idx = s.indexOf('十');
    if (idx < 0) return null;
    final hi = idx == 0 ? 1 : digits[s.substring(0, idx)];
    if (hi == null) return null;
    final tail = s.substring(idx + 1);
    if (tail.isEmpty) return hi * 10;
    final lo = digits[tail];
    if (lo == null) return null;
    return hi * 10 + lo;
  }

}

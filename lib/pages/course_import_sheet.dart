part of 'course_table_home_page.dart';

/// 课表导入的方式（用户点了右上角「导入」之后选）。
enum _ImportAction {
  /// 教工/学生统一认证 → 教务系统拉课表（= 原来的「刷新」）。
  campus,

  /// 从官网导出的 PDF 课表里解析。
  pdf,

  /// 从实验管理系统一键导入实验课（[sygl.cwxu.edu.cn]）。
  lab,

  /// 从截图/照片里本地 OCR 识别课程（T3）。
  image,

  /// 清空当前这份课表的全部课程（导入前的「归零」）。
  clearCurrent,

  /// 导入掌上锡院自己导出的方案文件（课表 / 外观 / 两者）。
  /// 选中后还会再问一次「导入哪一部分」，见 [_BundleImportKind]。
  bundle,
}

/// 「导入掌上锡院专属方案」之后的三选。
///
/// 三种文件在磁盘上都是同一套 JSON（schema 不同），用户不需要先判断文件里
/// 装的是什么 —— 他想只要课表就选课表，只要配色就选外观。分开的另一个原因：
/// [_BundleImportKind.all] 走 `importBundle()` 会连课表一起写进去，
/// 而「只想换个配色」的人绝不该被顺手覆盖课表。
enum _BundleImportKind {
  /// 只导课表（`CourseTransferService.importTables`）。
  tables,

  /// 只导外观（`CourseTransferService.importAppearance`），不碰课表。
  appearance,

  /// 课表 + 外观一起导（`CourseTransferService.importBundle`）。
  all,
}

/// 用户在某次导入面板里做出的选择。
class _ImportChoice {
  const _ImportChoice(this.action, {this.courses, this.title});

  final _ImportAction action;

  /// 只对 [pdf] 有效：解析出来的课程。
  final List<Course>? courses;

  /// 只对 [pdf] 有效：页面上的「XXX课表」，用来当默认表名。
  final String? title;
}

/// 「导入课表」面板。
///
/// 为什么要把刷新按钮换成导入按钮：原来右上角只有一个刷新图标，
/// 用户以为它是「重新读一下」，实际上它会**真的去教务抓一遍并合并**。
/// 而且抓取只有一种方式，PDF 课表（教务处网页上直接下载的那种）完全进不来。
///
/// 现在点一下先问「用哪种方式」，PDF 那条例还顺手把文件解析掉再返回。
class _CourseImportSheet extends StatefulWidget {
  const _CourseImportSheet({required this.tableName, required this.courseCount});

  /// 当前这份课表的名字与课程数 —— 用于「清空当前课表」那行的说明。
  final String tableName;
  final int courseCount;

  @override
  State<_CourseImportSheet> createState() => _CourseImportSheetState();
}

class _CourseImportSheetState extends State<_CourseImportSheet> {
  bool _parsingPdf = false;

  Future<void> _pickPdf() async {
    if (_parsingPdf) return;
    setState(() => _parsingPdf = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        // PDF 要整包解析，必须把字节读进来。
        withData: true,
      );
      final file = picked?.files.firstOrNull;
      final bytes = file?.bytes;
      if (bytes == null || bytes.isEmpty) {
        // 用户取消 / 读取失败都不弹错误，静默回到面板。
        if (mounted) setState(() => _parsingPdf = false);
        return;
      }
      final result = CoursePdfParser.parse(bytes);
      if (!mounted) return;
      if (result.courses.isEmpty) {
        setState(() => _parsingPdf = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这份 PDF 里没解析出课程，可能不是教务系统导出的课表'),
        ));
        return;
      }
      Navigator.of(context).pop(
        _ImportChoice(_ImportAction.pdf,
            courses: result.courses, title: result.title),
      );
    } on PdfUnsupportedException catch (e) {
      if (!mounted) return;
      setState(() => _parsingPdf = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } on PdfParseException catch (e) {
      if (!mounted) return;
      setState(() => _parsingPdf = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _parsingPdf = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取 PDF 失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : context.textPrimary;
    final sub = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);

    Widget row({
      required IconData icon,
      required String title,
      required VoidCallback? onTap,
      bool danger = false,
    }) {
      final color = danger ? const Color(0xFFE24B4A) : AppTheme.primaryColor;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2A2A2A) : Colors.white,
            border: Border.all(
                color: isDark ? Colors.grey.shade700 : const Color(0xFFE5E7EB)),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          ),
          child: Row(children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title,
                  style: TextStyle(fontSize: AppTheme.fontBody, color: fg)),
            ),
            if (onTap != null && !danger)
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: isDark ? Colors.grey.shade600 : sub),
          ]),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(
            color: isDark ? Colors.grey.shade800 : const Color(0xFFE5E7EB)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 10),
      title: const Text('导入课表',
          style: TextStyle(
              fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(
              icon: Icons.cloud_sync_rounded,
              title: '从教务系统导入',
              onTap: () =>
                  Navigator.of(context).pop(const _ImportChoice(_ImportAction.campus)),
            ),
            row(
              icon: Icons.picture_as_pdf_rounded,
              title: _parsingPdf ? '正在解析 PDF…' : '从 PDF 课表导入',
              onTap: _parsingPdf ? null : _pickPdf,
            ),
            row(
              icon: Icons.science_rounded,
              title: '导入实验课',
              onTap: () =>
                  Navigator.of(context).pop(const _ImportChoice(_ImportAction.lab)),
            ),
            row(
              icon: Icons.image_search_rounded,
              title: '从图片识别导入',
              onTap: () =>
                  Navigator.of(context).pop(const _ImportChoice(_ImportAction.image)),
            ),
            row(
              icon: Icons.inventory_2_outlined,
              title: '导入掌上锡院专属方案',
              onTap: () => Navigator.of(context)
                  .pop(const _ImportChoice(_ImportAction.bundle)),
            ),
            const SizedBox(height: 4),
            row(
              icon: Icons.delete_outline_rounded,
              title: widget.courseCount == 0
                  ? '清空当前课表'
                  : '清空当前课表（${widget.courseCount} 门）',
              onTap: widget.courseCount == 0
                  ? null
                  : () => Navigator.of(context)
                      .pop(const _ImportChoice(_ImportAction.clearCurrent)),
              danger: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

/// 「导入掌上锡院专属方案」的三选面板。
///
/// 居中盒子（用户 m06905 第 2 条：「居中新盒子」），样式与导入面板一致：
/// 白底 + 1px 细边框 + 圆角 + 右上角 ×。
class _BundleImportSheet extends StatelessWidget {
  const _BundleImportSheet();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : context.textPrimary;
    final sub = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);

    Widget row({
      required IconData icon,
      required String title,
      required String hint,
      required _BundleImportKind kind,
    }) {
      return InkWell(
        onTap: () => Navigator.of(context).pop(kind),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2A2A2A) : Colors.white,
            border: Border.all(
                color: isDark ? Colors.grey.shade700 : const Color(0xFFE5E7EB)),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          ),
          child: Row(children: [
            Icon(icon, size: 17, color: AppTheme.primaryColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: AppTheme.fontBody, color: fg)),
                  const SizedBox(height: 2),
                  Text(hint,
                      style: TextStyle(fontSize: AppTheme.fontSmall, color: sub)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: isDark ? Colors.grey.shade600 : sub),
          ]),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(
            color: isDark ? Colors.grey.shade800 : const Color(0xFFE5E7EB)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 10),
      title: Row(children: [
        const Expanded(
          child: Text('导入掌上锡院专属方案',
              style: TextStyle(
                  fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: '关闭',
          icon: Icon(Icons.close_rounded, size: 20, color: context.textTertiary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ]),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(
              icon: Icons.table_chart_rounded,
              title: '导入课程方案',
              hint: '只导入课表，不改当前外观',
              kind: _BundleImportKind.tables,
            ),
            row(
              icon: Icons.palette_outlined,
              title: '导入个性化外观方案',
              hint: '只换配色与显示设置，不碰课表',
              kind: _BundleImportKind.appearance,
            ),
            row(
              icon: Icons.inventory_2_outlined,
              title: '导入课表整体方案',
              hint: '课表 + 外观一起导入',
              kind: _BundleImportKind.all,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

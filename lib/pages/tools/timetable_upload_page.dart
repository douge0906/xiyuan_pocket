import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/course_model.dart';
import '../../models/course_table.dart';
import '../../services/course_storage.dart';
import '../../services/course_transfer_service.dart';
import '../../services/timetable/timetable_api.dart';
import '../../services/timetable/timetable_import_service.dart';
import '../../services/timetable/timetable_models.dart';
import '../../services/timetable/timetable_prefs.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/empty_state_art.dart';
import '../../widgets/state_views.dart';
import '../course/course_form_sheet.dart';

/// 上传班级课表（三步向导）。
///
/// 分三步不是为了好看：每一步都在收集**不同来源**的信息 ——
///   ① 这门课是谁的（班级归属）
///   ② 课表里有什么（课程列表，需要人工核对）
///   ③ 以谁的名义交（上传者名称 + 隐私自检 + 同意）
/// 三个来源的校验规则完全不同，混在一页里会让人填到一半才发现第一步就错了。
///
/// 相对设计稿的取舍：
///  · 来源选择从 2×2 网格改成**两行整宽卡片** —— 网格在小屏上两行文字会换行，
///    两张卡高度不一致，看起来像 bug。
///  · 「班级」允许手输：老师通知的班名和教务系统里的不完全一致（「25电气1班」
///    vs「电气25-1」），强制从列表里选会让一部分人传不上去。
class TimetableUploadPage extends StatefulWidget {
  const TimetableUploadPage({super.key, required this.term, this.presetClassKey});

  final TimetableTerm term;

  /// 从班级详情页进来时带上，省掉第一步。
  final String? presetClassKey;

  @override
  State<TimetableUploadPage> createState() => _TimetableUploadPageState();
}

class _TimetableUploadPageState extends State<TimetableUploadPage> {
  int _step = 0;
  bool _busy = false;
  String _error = '';

  late TimetableTerm _term;

  // ---- Step 1：归属
  final TextEditingController _jgmcCtl = TextEditingController();
  final TextEditingController _zymcCtl = TextEditingController();
  final TextEditingController _bjCtl = TextEditingController();
  final TextEditingController _njdmCtl = TextEditingController();
  String _source = 'local_table';

  // ---- Step 2：课程
  List<TimetableCourseItem> _courses = const [];
  List<TimetableCourseItem> _baseline = const [];
  bool _parsed = false;

  // ---- Step 3：上传者
  final TextEditingController _uploaderCtl = TextEditingController();
  final TextEditingController _noteCtl = TextEditingController();
  bool _agreed = false;

  @override
  void initState() {
    super.initState();
    _term = widget.term;
    _loadLastUploaderName();
  }

  /// 带出上次用过的上传者名称，省一次输入。真名/学号不预填 —— 那不该是我们做的事。
  Future<void> _loadLastUploaderName() async {
    final last = await TimetablePrefs.loadUploaderName();
    if (!mounted || last.isEmpty || _uploaderCtl.text.isNotEmpty) return;
    setState(() => _uploaderCtl.text = last);
  }

  @override
  void dispose() {
    _jgmcCtl.dispose();
    _zymcCtl.dispose();
    _bjCtl.dispose();
    _njdmCtl.dispose();
    _uploaderCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- Step 1

  /// 从本机课程表读课程。同时把这份表当成「校方基准」—— 用户能从教务导进
  /// 本机的课表，本身就是最接近官方的一份，用它算一致度最有意义。
  Future<void> _pickLocalTable() async {
    final tables = await CourseStorage.loadTables();
    if (!mounted) return;
    if (tables.isEmpty) {
      _toast('本机还没有课程表，先导入一份再来');
      return;
    }
    final activeId = await CourseStorage.activeTableId();
    if (!mounted) return;
    final picked = await showDialog<CourseTable>(
      context: context,
      builder: (_) => _TablePickDialog(tables: tables, activeId: activeId),
    );
    if (picked == null || !mounted) return;
    final items = TimetableImportService.fromCourses(picked.courses);
    setState(() {
      _source = 'local_table';
      _courses = items;
      _baseline = items;
      _parsed = true;
      _error = '';
      // 表名本身就常常是班级名，能填就填上。
      if (_bjCtl.text.trim().isEmpty && picked.name.trim().isNotEmpty) {
        _bjCtl.text = picked.name.trim();
      }
    });
    if (items.isEmpty) {
      _toast('这份课表里没有能上传的课程（每天/工作日模式的课会被跳过）');
    }
  }

  /// 从本机导出的 JSON 文件读课程。
  Future<void> _pickLocalFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      _toast('文件读不出来，换一个试试');
      return;
    }
    try {
      final items = TimetableImportService.parseFileBytes(bytes);
      if (items.isEmpty) {
        _toast('这个文件里没有能识别的课表');
        return;
      }
      setState(() {
        _source = 'local_file';
        _courses = items;
        _baseline = items;
        _parsed = true;
        _error = '';
      });
    } on CourseTransferException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('文件格式不认识，请用掌上锡院导出的课表文件');
    }
  }

  void _nextFromStep1() {
    if (_jgmcCtl.text.trim().isEmpty || _zymcCtl.text.trim().isEmpty || _bjCtl.text.trim().isEmpty) {
      setState(() => _error = '学院、专业、班级都要填');
      return;
    }
    if (!_parsed) {
      setState(() => _error = '先选一个来源，把课程读进来');
      return;
    }
    if (_courses.isEmpty) {
      setState(() => _error = '这份课表里没有课程');
      return;
    }
    setState(() {
      _error = '';
      _step = 1;
    });
  }

  // ---------------------------------------------------------------- Step 2

  void _editCourse(int index) {
    final c = _courses[index];
    showCourseFormSheet(
      context,
      course: Course(
        id: 'tt_draft_${identityHashCode(c)}',
        name: c.name,
        teacher: c.teacher,
        classroom: c.classroom,
        weekday: c.weekday,
        startSlot: c.startSlot,
        endSlot: c.endSlot,
        weeks: c.weeks,
        colorValue: colorForName(c.name),
        source: CourseSource.imported,
      ),
      onSave: (edited) {
        if (!mounted) return;
        setState(() {
          _courses = TimetableImportService.replaceAt(
            _courses,
            index,
            TimetableCourseItem(
              name: edited.name.trim(),
              teacher: edited.teacher.trim(),
              classroom: edited.classroom.trim(),
              weekday: edited.weekday,
              startSlot: edited.startSlot,
              endSlot: edited.endSlot,
              weeks: edited.weeks.trim(),
            ),
          );
        });
      },
      onDelete: (_) {
        if (!mounted) return;
        setState(() {
          _courses = TimetableImportService.removeAt(_courses, index);
        });
      },
    );
  }

  // ---------------------------------------------------------------- Step 3

  Future<void> _submit() async {
    if (_busy) return;
    final uploader = _uploaderCtl.text.trim();
    if (uploader.isEmpty) {
      setState(() => _error = '请填一个上传者名称');
      return;
    }
    if (uploader.runes.length > 16) {
      setState(() => _error = '上传者名称最多 16 个字');
      return;
    }
    if (!_agreed) {
      setState(() => _error = '请先勾选「我确认以上内容没有问题」');
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });
    final payload = <String, dynamic>{
      'xnm': _term.xnm,
      'xqm': _term.xqm,
      'jgmc': _jgmcCtl.text.trim(),
      'zymc': _zymcCtl.text.trim(),
      'bj': _bjCtl.text.trim(),
      'njdmId': _njdmCtl.text.trim(),
      'source': _source,
      'uploaderName': uploader,
      'note': _noteCtl.text.trim(),
      'courses': TimetableImportService.toRequestList(_courses),
      if (_baseline.isNotEmpty)
        'campusBaseline': TimetableImportService.toRequestList(_baseline),
    };

    final result = await TimetableApi.createUpload(payload);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      setState(() => _error = result.message);
      return;
    }
    unawaited(TimetablePrefs.saveUploaderName(uploader));
    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('已提交，审核通过后同学们就能检索到'),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('上传班级课表',
            style: TextStyle(
                fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            if (_step > 0) {
              setState(() => _step -= 1);
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: Column(
        children: [
          _stepper(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (_error.isNotEmpty) _errorBar(),
                if (_step == 0) ..._step1(),
                if (_step == 1) ..._step2(),
                if (_step == 2) ..._step3(),
              ],
            ),
          ),
          _bottomBar(),
        ],
      ),
    );
  }

  Widget _stepper() {
    const labels = ['班级归属', '课程核对', '上传者'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 1.4,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: i <= _step ? AppTheme.primaryColor : context.borderColor,
                ),
              ),
            Column(children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i <= _step ? AppTheme.primaryColor : context.subtleFill,
                  border: Border.all(
                      color: i <= _step ? AppTheme.primaryColor : context.borderColor),
                ),
                child: Text('${i + 1}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: i <= _step ? Colors.white : context.textTertiary)),
              ),
              const SizedBox(height: 3),
              Text(labels[i],
                  style: TextStyle(
                      fontSize: 10.5,
                      color: i <= _step ? AppTheme.primaryColor : context.textTertiary)),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _errorBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.dangerColor.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(color: context.dangerColor.withValues(alpha: .3)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline_rounded, size: 16, color: context.dangerColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(_error,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, height: 1.4, color: context.dangerColor)),
          ),
        ]),
      ),
    );
  }

  List<Widget> _step1() {
    return [
      _label('这门课表是谁的'),
      const SizedBox(height: 8),
      _field(_jgmcCtl, '学院', hint: '例如：智能工程学院'),
      _field(_zymcCtl, '专业', hint: '例如：电气工程及其自动化'),
      _field(_bjCtl, '班级', hint: '例如：25电气1班'),
      _field(_njdmCtl, '年级（可不填）', hint: '例如：2025'),
      const SizedBox(height: 6),
      Text('班级可以手动改。老师通知的班名和教务系统里的经常不一样，按你们班同学认得的方式填就行。',
          style: TextStyle(
              fontSize: AppTheme.fontCaption, height: 1.45, color: context.textTertiary)),
      const SizedBox(height: 18),
      _label('课程从哪里来'),
      const SizedBox(height: 8),
      _sourceCard(
        value: 'local_table',
        icon: Icons.table_chart_rounded,
        title: '从本机课程表导入',
        hint: '选一份你本机已有的课表，直接拿来上传',
        onTap: _pickLocalTable,
      ),
      _sourceCard(
        value: 'local_file',
        icon: Icons.file_open_rounded,
        title: '从本机导出的文件导入',
        hint: '掌上锡院「课表设置 → 导出课表整体方案」得到的文件',
        onTap: _pickLocalFile,
      ),
      const SizedBox(height: 10),
      _termRow(),
      if (_courses.isNotEmpty) ...[
        const SizedBox(height: 14),
        _parsedSummary(),
      ],
    ];
  }

  Widget _sourceCard({
    required String value,
    required IconData icon,
    required String title,
    required String hint,
    required VoidCallback onTap,
  }) {
    final on = _source == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: on ? AppTheme.primaryColor.withValues(alpha: .06) : context.cardColor,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(
                color: on ? AppTheme.primaryColor : context.borderColor,
                width: on ? 1.4 : 1),
          ),
          child: Row(children: [
            Icon(icon, size: 19, color: on ? AppTheme.primaryColor : context.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                        color: on ? AppTheme.primaryColor : context.textPrimary)),
                const SizedBox(height: 1),
                Text(hint,
                    maxLines: 2,
                    style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
              ]),
            ),
            if (on) Icon(Icons.check_circle_rounded, size: 18, color: AppTheme.primaryColor),
          ]),
        ),
      ),
    );
  }

  Widget _termRow() {
    return InkWell(
      onTap: _pickTerm,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.subtleFill,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Row(children: [
          Icon(Icons.event_note_rounded, size: 17, color: context.textSecondary),
          const SizedBox(width: 8),
          Text('学年学期',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_term.label,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary)),
          ),
          Icon(Icons.expand_more_rounded, size: 18, color: context.textTertiary),
        ]),
      ),
    );
  }

  Future<void> _pickTerm() async {
    // 复用检索页那套：只允许服务端的三个学期值。
    final picked = await showDialog<TimetableTerm>(
      context: context,
      builder: (_) => _SimpleTermDialog(current: _term),
    );
    if (picked == null || !mounted) return;
    setState(() => _term = picked);
  }

  Widget _parsedSummary() {
    final issues = TimetableImportService.issueCount(_courses);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.successColor.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: context.successColor.withValues(alpha: .25)),
      ),
      child: Row(children: [
        Icon(Icons.check_circle_outline_rounded, size: 16, color: context.successColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text('已读取 ${_courses.length} 门课程${issues > 0 ? '，其中 $issues 门需要核对' : ''}',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.successColor)),
        ),
      ]),
    );
  }

  List<Widget> _step2() {
    final issues = TimetableImportService.issueCount(_courses);
    return [
      if (issues > 0) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: context.warningColor.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(color: context.warningColor.withValues(alpha: .32)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.error_outline_rounded, size: 16, color: context.warningColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text('已解析 ${_courses.length} 门课程，$issues 处需要你确认。点一下课程就能改。',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall, height: 1.4, color: context.warningColor)),
            ),
          ]),
        ),
        const SizedBox(height: 12),
      ] else ...[
        Text('已解析 ${_courses.length} 门课程，看起来没问题。点一下可以改。',
            style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary)),
        const SizedBox(height: 12),
      ],
      for (var i = 0; i < _courses.length; i++) _courseCard(i),
      const SizedBox(height: 4),
      Text(
        '只核对不上传也没关系：提交后还有人工审核。缺周次、缺教室的课最好补上，不然别的班同学导进去会缺课。',
        style: TextStyle(
            fontSize: AppTheme.fontCaption, height: 1.45, color: context.textTertiary),
      ),
    ];
  }

  Widget _courseCard(int index) {
    final c = _courses[index];
    final issues = TimetableImportService.issuesOf(_courses, index);
    final hasIssue = issues.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _editCourse(index),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: context.cardColor,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(
                color: hasIssue ? context.warningColor.withValues(alpha: .55) : context.borderColor,
                width: hasIssue ? 1.4 : 1),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary)),
                  ),
                  Text(c.slotLabel,
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                ]),
                const SizedBox(height: 2),
                Text(
                  [
                    _dayName(c.weekday),
                    if (c.teacher.isNotEmpty) c.teacher,
                    if (c.classroom.isNotEmpty) '@${c.classroom}',
                    if (c.weeks.isNotEmpty) c.weeks,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary),
                ),
                if (hasIssue) ...[
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: [
                      for (final t in issues)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: context.warningColor.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(t,
                              style: TextStyle(
                                  fontSize: 10.5, color: context.warningColor)),
                        ),
                    ],
                  ),
                ],
              ]),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: context.textTertiary),
          ]),
        ),
      ),
    );
  }

  List<Widget> _step3() {
    return [
      _label('上传者名称'),
      const SizedBox(height: 6),
      Text('会显示给看这份课表的同学。填一个班里都认得的昵称就行。',
          style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
      const SizedBox(height: 8),
      TextField(
        controller: _uploaderCtl,
        maxLength: 16,
        style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary),
        decoration: _decoration('例如：张同学'),
      ),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.subtleFill,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.privacy_tip_outlined, size: 15, color: context.textSecondary),
            const SizedBox(width: 6),
            Text('隐私自检',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: context.textSecondary)),
          ]),
          const SizedBox(height: 4),
          Text(
            '· 上传者名称请填昵称，不要填真实姓名、学号、手机号\n'
            '· 课程里的教室、教师名是公开信息，没问题\n'
            '· 服务器只保存昵称和一份设备标识，不保存学号明文',
            style: TextStyle(
                fontSize: AppTheme.fontCaption, height: 1.55, color: context.textTertiary),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      _label('补充说明（可不填）'),
      const SizedBox(height: 8),
      TextField(
        controller: _noteCtl,
        maxLines: 3,
        maxLength: 500,
        style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary),
        decoration: _decoration('例如：实验课的教室是按老师通知填的'),
      ),
      const SizedBox(height: 6),
      InkWell(
        onTap: () => setState(() => _agreed = !_agreed),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_agreed ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                size: 20,
                color: _agreed ? AppTheme.primaryColor : context.textTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('我确认这份课表内容和班级归属没有填错，愿意让它公开给同学检索。',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      height: 1.45,
                      color: context.textSecondary)),
            ),
          ]),
        ),
      ),
    ];
  }

  Widget _label(String text) {
    return Text(text,
        style: TextStyle(
            fontSize: AppTheme.fontSmall,
            fontWeight: FontWeight.w600,
            color: context.textSecondary));
  }

  Widget _field(TextEditingController ctl, String label, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctl,
        style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary),
        decoration: _decoration(hint ?? '').copyWith(labelText: label),
      ),
    );
  }

  InputDecoration _decoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: AppTheme.fontBody, color: context.textTertiary),
      isDense: true,
      filled: true,
      fillColor: context.cardColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      counterStyle: TextStyle(fontSize: 10.5, color: context.textTertiary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        borderSide: BorderSide(color: context.borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        borderSide: BorderSide(color: context.borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        borderSide: BorderSide(color: AppTheme.primaryColor),
      ),
    );
  }

  Widget _bottomBar() {
    final isLast = _step == 2;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Row(children: [
          if (_step > 0)
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => setState(() => _step -= 1),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: context.borderColor),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                ),
                child: Text('上一步',
                    style: TextStyle(fontSize: AppTheme.fontBody, color: context.textSecondary)),
              ),
            ),
          if (_step > 0) const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : (isLast
                      ? _submit
                      : (_step == 0 ? _nextFromStep1 : () => setState(() => _step = 2))),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : Text(isLast ? '提交审核' : '下一步',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
  }

  static String _dayName(int w) {
    const names = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return (w >= 1 && w <= 7) ? names[w] : '周?';
  }
}

/// 选一份本机课表。
class _TablePickDialog extends StatelessWidget {
  const _TablePickDialog({required this.tables, required this.activeId});

  final List<CourseTable> tables;
  final String activeId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: context.borderColor),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      title: Row(children: [
        const Expanded(
          child: Text('选一份课表',
              style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 380),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final t in tables)
                InkWell(
                  onTap: () => Navigator.of(context).pop(t),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    child: Row(children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${t.name}${t.id == activeId ? '（当前）' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  fontWeight: FontWeight.w600,
                                  color: context.textPrimary),
                            ),
                            const SizedBox(height: 1),
                            Text('${t.courses.length} 门课',
                                style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: context.textTertiary)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, size: 18, color: context.textTertiary),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: const [],
    );
  }
}

/// 上传页里的学期选择。与检索页那个只差标题与可选范围。
class _SimpleTermDialog extends StatefulWidget {
  const _SimpleTermDialog({required this.current});

  final TimetableTerm current;

  @override
  State<_SimpleTermDialog> createState() => _SimpleTermDialogState();
}

class _SimpleTermDialogState extends State<_SimpleTermDialog> {
  late final List<TimetableTerm> _terms;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final (xnm, xqm) = CourseStorage.semesterArgsFor(now);
    final current = TimetableTerm(xnm, xqm);
    final prevYear = (int.tryParse(xnm.split('-').first) ?? now.year) - 1;
    final prev = xqm == '3'
        ? TimetableTerm('$prevYear-${prevYear + 1}', '12')
        : TimetableTerm(xnm, '3');
    final seen = <TimetableTerm>{};
    _terms = [prev, current, current.next]
        .where((t) => seen.add(t))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: context.borderColor),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      title: Row(children: [
        const Expanded(
          child: Text('选择学年学期',
              style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final t in _terms)
            InkWell(
              onTap: () => Navigator.of(context).pop(t),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(children: [
                  Expanded(
                    child: Text(t.label,
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          color: t == widget.current
                              ? AppTheme.primaryColor
                              : context.textPrimary,
                          fontWeight:
                              t == widget.current ? FontWeight.w600 : FontWeight.w400,
                        )),
                  ),
                  if (t == widget.current)
                    Icon(Icons.check_rounded, size: 18, color: AppTheme.primaryColor),
                ]),
              ),
            ),
        ]),
      ),
      actions: const [],
    );
  }
}

/// 「我的上传」：跟踪自己交过的每一份，看到审核结果并处理驳回。
///
/// 数据全在服务端（按设备归属），所以换手机也能看到自己传过什么 —— 这也是
/// 为什么用 `contributor`（设备级不透明键）而不是本地缓存。
class TimetableMyUploadsPage extends StatefulWidget {
  const TimetableMyUploadsPage({super.key});

  @override
  State<TimetableMyUploadsPage> createState() => _TimetableMyUploadsPageState();
}

class _TimetableMyUploadsPageState extends State<TimetableMyUploadsPage>
    with WidgetsBindingObserver {
  bool _loading = true;
  String _error = '';
  List<TimetableOwnUpload> _all = const [];
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台静默刷新：用户很可能刚在后台被别人审核了。
    if (state == AppLifecycleState.resumed) {
      unawaited(_load(silent: true));
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    final result = await TimetableApi.myUploads();
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _loading = false;
        _error = result.message;
      });
      return;
    }
    final list = <TimetableOwnUpload>[];
    for (final item in result.listOf('uploads')) {
      final u = TimetableOwnUpload.fromJson(item);
      if (u != null) list.add(u);
    }
    setState(() {
      _loading = false;
      _all = list;
    });
  }

  List<TimetableOwnUpload> get _shown {
    if (_filter == 'all') return _all;
    if (_filter == 'approved') return _all.where((u) => u.isApproved).toList();
    if (_filter == 'rejected') return _all.where((u) => u.isRejected).toList();
    return _all.where((u) => u.status == _filter).toList();
  }

  int _countOf(String key) {
    if (key == 'all') return _all.length;
    if (key == 'approved') return _all.where((u) => u.isApproved).length;
    return _all.where((u) => u.status == key).length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('我的上传',
            style: TextStyle(
                fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : () => _load(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_loading && _error.isEmpty) _filterRow(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _filterRow() {
    const keys = [
      ('all', '全部'),
      ('pending', '待审核'),
      ('approved', '已通过'),
      ('rejected', '已驳回'),
      ('removed', '已下架'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(children: [
        for (final (key, label) in keys)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () => setState(() => _filter = key),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _filter == key
                      ? AppTheme.primaryColor.withValues(alpha: .08)
                      : context.subtleFill,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  border: Border.all(
                      color: _filter == key ? AppTheme.primaryColor : context.borderColor),
                ),
                child: Text('$label ${_countOf(key)}',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: _filter == key
                            ? AppTheme.primaryColor
                            : context.textSecondary)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return ListView(children: [
        const SizedBox(height: 80),
        ErrorState(message: _error, onRetry: () => _load()),
      ]);
    }
    final shown = _shown;
    if (shown.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 70),
        EmptyState(
          message: _filter == 'all' ? '还没有上传过课表' : '这个状态下没有记录',
          hint: '在班级检索页右上角可以上传',
          icon: Icons.upload_file_outlined,
          artVariant: EmptyArtVariant.inbox,
        ),
      ]);
    }
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        itemCount: shown.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _card(shown[i]),
      ),
    );
  }

  Widget _card(TimetableOwnUpload u) {
    final color = switch (u.status) {
      'approved' => context.successColor,
      'rejected' => context.dangerColor,
      'removed' => context.textTertiary,
      _ => context.warningColor,
    };
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${u.bj}  v${u.version}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: AppTheme.fontTitle,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Text(u.statusLabel,
                style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ),
        ]),
        const SizedBox(height: 4),
        Text('${u.courseCount} 门 · ${u.uploaderName} · ${u.sourceLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary)),
        const SizedBox(height: 2),
        Text(timetableRelativeTime(u.createdAt),
            style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
        if (u.isRejected) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: context.dangerColor.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              border: Border.all(color: context.dangerColor.withValues(alpha: .25)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '驳回原因：${u.reviewReasonText.isEmpty ? '未说明' : u.reviewReasonText}',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: context.dangerColor),
              ),
              if (u.reviewNote.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(u.reviewNote.trim(),
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        height: 1.4,
                        color: context.textSecondary)),
              ],
            ]),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: () => _resubmit(u),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                ),
                child: const Text('改完重提',
                    style: TextStyle(fontSize: AppTheme.fontSmall, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _revoke(u),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  side: BorderSide(color: context.borderColor),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                ),
                child: Text('撤销',
                    style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary)),
              ),
            ),
          ]),
        ],
        if (u.isPending) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _revoke(u),
              child: Text('撤销这次上传',
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: context.dangerColor)),
            ),
          ),
        ],
        if (u.isApproved && !u.published) ...[
          const SizedBox(height: 6),
          Text('审核通过了，正在发布到线上，一般几秒到一分钟。稍后下拉刷新看看。',
              style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
        ],
      ]),
    );
  }

  Future<void> _revoke(TimetableOwnUpload u) async {
    final ok = await _confirmDialog(
      title: '撤销这次上传？',
      body: '「${u.bj}」v${u.version} 会从服务器删掉，以后要重新上传。',
      confirmText: '撤销',
      danger: true,
    );
    if (ok != true || !mounted) return;
    final result = await TimetableApi.revokeUpload(u.id);
    if (!mounted) return;
    if (!result.ok) {
      _toast(result.message);
      return;
    }
    _toast('已撤销');
    await _load(silent: true);
  }

  Future<void> _resubmit(TimetableOwnUpload u) async {
    // 重提要重新走一遍三步向导（内容可能改了很多），但 id 要带上，
    // 让服务端在原行上 version+1 而不是新建一条。
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TimetableResubmitPage(upload: u),
      ),
    );
    if (done == true && mounted) await _load(silent: true);
  }

  Future<bool?> _confirmDialog({
    required String title,
    required String body,
    required String confirmText,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => _confirmBody(
        context: ctx,
        title: title,
        body: body,
        confirmText: confirmText,
        danger: danger,
      ),
    );
  }

  /// 只造盒子，不负责弹。`showDialog` 的 builder 要返回 Widget，
  /// 所以不能把「弹」写在这个函数里。
  Widget _confirmBody({
    required BuildContext context,
    required String title,
    required String body,
    required String confirmText,
    bool danger = false,
  }) {
    return AlertDialog(
        backgroundColor: context.cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: context.borderColor),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 10),
        title: Row(children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ]),
        content: Text(body,
            style: TextStyle(
                fontSize: AppTheme.fontSmall, height: 1.5, color: context.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('取消',
                    style: TextStyle(fontSize: AppTheme.fontBody, color: context.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: danger ? context.dangerColor : AppTheme.primaryColor,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
            ),
            child: Text(confirmText),
          ),
        ],
      );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
  }
}

/// 驳回后「改完重提」。
///
/// 复用上传向导的课程核对部分，但归属与来源不让改 —— 那条记录在服务端已经
/// 挂在原来的班级下了，改归属会变成「用旧记录的名义投到别的班」，审核员看到
/// 的班级和实际不符。真要换班，撤销后重新上传。
class TimetableResubmitPage extends StatefulWidget {
  const TimetableResubmitPage({super.key, required this.upload});

  final TimetableOwnUpload upload;

  @override
  State<TimetableResubmitPage> createState() => _TimetableResubmitPageState();
}

class _TimetableResubmitPageState extends State<TimetableResubmitPage> {
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  List<TimetableCourseItem> _courses = const [];
  List<TimetableCourseItem> _baseline = const [];
  late final TextEditingController _uploaderCtl;
  late final TextEditingController _noteCtl;
  bool _agreed = true;

  @override
  void initState() {
    super.initState();
    _uploaderCtl = TextEditingController(text: widget.upload.uploaderName);
    _noteCtl = TextEditingController();
    _loadCourses();
  }

  @override
  void dispose() {
    _uploaderCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  /// 驳回记录本身不带课程明细（列表接口为了轻量没返回），要回到班级详情
  /// 里用「我的上传」那条 id 找回来 —— 这里改成从班级详情拿「自己那条」。
  /// 拿不到就让用户重新选来源，不假装成功。
  Future<void> _loadCourses() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final result = await TimetableApi.classDetail(_classKeyOf(widget.upload));
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _loading = false;
        _error = result.message;
      });
      return;
    }
    final detail = TimetableClassDetail.fromJson(result.data);
    // 已发布的版本里可能没有自己那条（被驳回的不在可见列表里）。
    // 所以这里只当"参考"，让用户重新挑来源更可靠。
    setState(() {
      _loading = false;
      _courses = const [];
      _baseline = detail?.timetables.isNotEmpty == true
          ? detail!.timetables.first.courses
          : const [];
    });
  }

  String _classKeyOf(TimetableOwnUpload u) =>
      '${u.xnm}-${u.xqm}|${u.jgmc}|${u.zymc}|${u.bj}';

  Future<void> _pickLocalTable() async {
    final tables = await CourseStorage.loadTables();
    if (!mounted) return;
    if (tables.isEmpty) {
      _toast('本机还没有课程表');
      return;
    }
    final picked = await showDialog<CourseTable>(
      context: context,
      builder: (_) => _TablePickDialog(tables: tables, activeId: ''),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _courses = TimetableImportService.fromCourses(picked.courses);
      _error = '';
    });
  }

  Future<void> _pickLocalFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final bytes = picked.files.first.bytes;
    if (bytes == null || bytes.isEmpty) return;
    try {
      final items = TimetableImportService.parseFileBytes(bytes);
      if (items.isEmpty) {
        _toast('这个文件里没有能识别的课表');
        return;
      }
      setState(() {
        _courses = items;
        _error = '';
      });
    } catch (_) {
      _toast('文件格式不认识');
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_courses.isEmpty) {
      setState(() => _error = '先重新选一下课程来源');
      return;
    }
    final uploader = _uploaderCtl.text.trim();
    if (uploader.isEmpty || uploader.runes.length > 16) {
      setState(() => _error = '上传者名称 1~16 个字');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final payload = <String, dynamic>{
      'xnm': widget.upload.xnm,
      'xqm': widget.upload.xqm,
      'jgmc': widget.upload.jgmc,
      'zymc': widget.upload.zymc,
      'bj': widget.upload.bj,
      'source': widget.upload.source,
      'uploaderName': uploader,
      'note': _noteCtl.text.trim(),
      'courses': TimetableImportService.toRequestList(_courses),
      if (_baseline.isNotEmpty)
        'campusBaseline': TimetableImportService.toRequestList(_baseline),
    };
    final result = await TimetableApi.resubmit(widget.upload.id, payload);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      setState(() => _error = result.message);
      return;
    }
    unawaited(TimetablePrefs.saveUploaderName(uploader));
    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('已重新提交，等审核'),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('改完重提',
            style: TextStyle(
                fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text('${widget.upload.bj} · 原 v${widget.upload.version}',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary)),
                const SizedBox(height: 4),
                Text('要改的只是内容：班级归属保持不变。真要换班请先撤销再重新上传。',
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                const SizedBox(height: 12),
                if (_error.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: context.dangerColor.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: Text(_error,
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall, color: context.dangerColor)),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _pickLocalTable,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        side: BorderSide(color: context.borderColor),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                      ),
                      child: Text('从本机课表读',
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textPrimary)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _pickLocalFile,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        side: BorderSide(color: context.borderColor),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                      ),
                      child: Text('从文件读',
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textPrimary)),
                    ),
                  ),
                ]),
                if (_courses.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: context.successColor.withValues(alpha: .07),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: Text('已读取 ${_courses.length} 门课程',
                        style: TextStyle(fontSize: AppTheme.fontSmall, color: context.successColor)),
                  ),
                  const SizedBox(height: 12),
                  for (var i = 0; i < _courses.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            '${_dayName(_courses[i].weekday)} ${_courses[i].slotLabel} · ${_courses[i].name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: AppTheme.fontSmall, color: context.textPrimary),
                          ),
                        ),
                      ]),
                    ),
                ],
                const SizedBox(height: 14),
                TextField(
                  controller: _uploaderCtl,
                  maxLength: 16,
                  style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary),
                  decoration: InputDecoration(
                    labelText: '上传者名称',
                    isDense: true,
                    filled: true,
                    fillColor: context.cardColor,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _noteCtl,
                  maxLines: 2,
                  maxLength: 500,
                  style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary),
                  decoration: InputDecoration(
                    hintText: '补充说明（可不填）',
                    isDense: true,
                    filled: true,
                    fillColor: context.cardColor,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () => setState(() => _agreed = !_agreed),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(
                        _agreed
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 20,
                        color: _agreed ? AppTheme.primaryColor : context.textTertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('我确认内容已经按驳回意见改好了。',
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textSecondary)),
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy || !_agreed ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Colors.white),
                          )
                        : const Text('重新提交',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
    );
  }

  static String _dayName(int w) {
    const names = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return (w >= 1 && w <= 7) ? names[w] : '周?';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
  }
}

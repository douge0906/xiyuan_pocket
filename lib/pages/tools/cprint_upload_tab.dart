import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/campus/jwgl_client.dart' show CampusException;
import '../../services/campus/cprint_client.dart';
import '../../services/campus/cprint_models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import 'cprint_shared.dart';

/// 云打印 · 「云打印」页签（上传文件去打印）。
///
/// 对应网页版 `cprint.html`。移动端和网页版有两处必须不一样：
///
/// * 网页版把「纸型 / 单双面 / 份数」平铺成一行行 radio，手机上照抄会占掉
///   两屏。这里改成「折叠的选项行 + 一行摘要」，默认值就是网页版的默认值。
/// * **PDF 要单独警告**：这台服务器传 PDF 会挂死（45~120 秒无响应、任务也
///   不进队列），传图片秒回。这是实测出来的，不是猜的。用户上传 PDF 时给
///   黄色提示，不要等到超时才让他知道。
class CprintUploadTab extends StatefulWidget {
  const CprintUploadTab({super.key, this.onUploaded});

  /// 上传成功后通知外层（外层用来切到「打印文档」页签）。
  final VoidCallback? onUploaded;

  @override
  State<CprintUploadTab> createState() => _CprintUploadTabState();
}

class _CprintUploadTabState extends State<CprintUploadTab> {
  PlatformFile? _file;
  bool _color = false;
  int _paperId = -1;
  int _duplex = 1;
  int _copies = 1;
  bool _busy = false;

  static const _exts = [
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'jpg',
    'jpeg',
    'png',
  ];

  Future<void> _pick() async {
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _exts,
        withData: false,
      );
      if (!mounted) return;
      final f = (r == null || r.files.isEmpty) ? null : r.files.first;
      if (f == null) return;
      // 系统文件选择器是原生页面，用户可能停留很久，回来时页面可能已重建。
      if ((f.path ?? '').isEmpty) {
        _toast('读不到这个文件，换一个试试');
        return;
      }
      setState(() => _file = f);
    } catch (_) {
      _toast('无法打开文件选择器');
    }
  }

  bool get _isPdf => (_file?.name ?? '').toLowerCase().endsWith('.pdf');

  String get _paperLabel => switch (_paperId) {
        -1 => '不指定',
        9 => 'A4',
        8 => 'A3',
        _ => '不指定',
      };

  String get _duplexLabel => switch (_duplex) {
        1 => '单面',
        2 => '双面短边',
        3 => '双面长边',
        _ => '单面',
      };

  Future<void> _submit() async {
    final f = _file;
    if (f == null || _busy) return;
    setState(() => _busy = true);
    final nav = Navigator.of(context, rootNavigator: true);
    var dialogOpen = true;
    // 上传可能要几十秒（大文件），必须有进度反馈。这个接口没有百分比，
    // 用不确定进度的转圈 + 「正在上传」。
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: context.cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            side: BorderSide(color: context.borderColor),
          ),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor: AlwaysStoppedAnimation(AppTheme.primaryColor),
                ),
              ),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  '正在上传到图书馆云打印，请不要离开',
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: context.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    try {
      final bytes = await File(f.path!).readAsBytes();
      final r = await CprintClient.upload(
        fileName: f.name,
        bytes: bytes,
        contentType: _contentTypeFor(f.name),
        color: _color,
        paperId: _paperId,
        duplex: _duplex,
        copies: _copies,
      );
      if (!mounted) return;
      dialogOpen = false;
      nav.pop();
      if (!r.ok) {
        _toast(r.message.isEmpty ? '上传没有成功，请稍后再试。' : r.message);
        return;
      }
      await _showDone(r);
      if (!mounted) return;
      setState(() => _file = null);
      widget.onUploaded?.call();
    } on TimeoutException {
      // 实测（2026-11-25）：PDF 打到这台服务器会卡在转换那一步整整两分钟，
      // 客户端 25 秒就超时。这时候说「读取文件失败」既不准确也帮不上忙。
      if (!mounted) return;
      if (dialogOpen) {
        dialogOpen = false;
        nav.pop();
      }
      _toast(_isPdf
          ? 'PDF 上传超时了。图书馆这台服务器转 PDF 经常卡住，建议先把 PDF 转成图片再传。'
          : '上传超时了，请检查网络后重试。');
    } on CampusException catch (err) {
      if (!mounted) return;
      if (dialogOpen) {
        dialogOpen = false;
        nav.pop();
      }
      _toast(err.message.isEmpty ? '上传没有成功，请稍后再试。' : err.message);
    } catch (e) {
      if (!mounted) return;
      if (dialogOpen) {
        dialogOpen = false;
        nav.pop();
      }
      debugPrint('[cprint] upload 未预期异常：$e');
      _toast('这个文件没能传上去，换一个再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _contentTypeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.txt')) return 'text/plain';
    return 'application/octet-stream';
  }

  Future<void> _showDone(CprintUploadResult r) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: ctx.borderColor),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 8, 0),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '已上传到云打印',
                style: TextStyle(
                  fontSize: AppTheme.fontHeading,
                  fontWeight: FontWeight.w600,
                  color: ctx.textPrimary,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              icon: Icon(Icons.close_rounded, size: 20, color: ctx.textTertiary),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '下一步去打印机旁的终端刷卡打印。文件会留在云打印账号里，'
              '在「打印文档」也能看到。',
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                height: 1.55,
                color: ctx.textSecondary,
              ),
            ),
            if (r.feeLabel.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '预计费用 ${r.feeLabel}',
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: ctx.textPrimary,
                ),
              ),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        if (f == null)
          _pickCard()
        else ...[
          _fileCard(f),
          const SizedBox(height: 12),
          _options(),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? '正在上传…' : '上传到云打印'),
            ),
          ),
          const SizedBox(height: 10),
          cprintHint(
            context,
            '纸型和单双面有些文档不支持，实际以打印机为准。'
            '上传后到打印机旁刷卡就能打。',
          ),
        ],
      ],
    );
  }

  Widget _pickCard() {
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Icon(Icons.upload_file_rounded,
                size: 27, color: AppTheme.primaryColor),
          ),
          const SizedBox(height: 14),
          Text(
            '选一个文件，传到图书馆的打印机',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontTitle,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '支持 PDF、Word、Excel、PPT、TXT 和图片。'
            '传好后去打印机旁的终端刷卡打印。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              height: 1.55,
              color: context.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('选择文件'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileCard(PlatformFile f) {
    final lower = f.name.toLowerCase();
    final isPdf = lower.endsWith('.pdf');
    final isPic = lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg');
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
      child: Row(
        children: [
          cprintTypeIcon(CprintDocType.fromName(f.name), size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w500,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${cprintSize(f.size)} · ${isPic ? '图片' : isPdf ? 'PDF' : '文档'}',
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: context.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _pick,
            child: const Text('换一个'),
          ),
        ],
      ),
    );
  }

  Widget _options() {
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Column(
        children: [
          _optionRow(
            '颜色',
            [
              _chip('黑白', !_color, () => setState(() => _color = false)),
              _chip('彩色', _color, () => setState(() => _color = true)),
            ],
          ),
          Divider(height: 1, color: context.borderColor),
          _optionRow(
            '纸张',
            [
              _chip('不指定', _paperId == -1, () => setState(() => _paperId = -1)),
              _chip('A4', _paperId == 9, () => setState(() => _paperId = 9)),
              _chip('A3', _paperId == 8, () => setState(() => _paperId = 8)),
            ],
          ),
          Divider(height: 1, color: context.borderColor),
          _optionRow(
            '单双面',
            [
              _chip('单面', _duplex == 1, () => setState(() => _duplex = 1)),
              _chip('双面短边', _duplex == 2, () => setState(() => _duplex = 2)),
              _chip('双面长边', _duplex == 3, () => setState(() => _duplex = 3)),
            ],
          ),
          Divider(height: 1, color: context.borderColor),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 62,
                  child: Text(
                    '份数',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      color: context.textSecondary,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '$_copies 份',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '减少',
                  visualDensity: VisualDensity.compact,
                  onPressed: _copies <= 1
                      ? null
                      : () => setState(() => _copies -= 1),
                  icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
                ),
                IconButton(
                  tooltip: '增加',
                  visualDensity: VisualDensity.compact,
                  onPressed: _copies >= 99
                      ? null
                      : () => setState(() => _copies += 1),
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              '${_color ? '彩色' : '黑白'} · $_paperLabel · $_duplexLabel · $_copies 份',
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: context.textTertiary,
              ),
            ),
          ),
          if ((_file?.name ?? '').toLowerCase().endsWith('.pdf')) ...[
            Divider(height: 1, color: context.borderColor),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 16, color: context.warningColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      // 实测：这台服务器转 PDF 的链路是坏的，传 PDF 会一直转圈
                      // 直到超时，任务也不会进队列。图片是好的。
                      'PDF 在图书馆这台服务器上经常传不上去，建议先在手机里转成图片。',
                      style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        height: 1.4,
                        color: context.warningColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _optionRow(String title, List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  color: context.textSecondary,
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(spacing: 8, runSpacing: 6, children: chips),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

import 'package:flutter/material.dart';

import '../services/dorm_service.dart';

/// 宿舍填写弹窗（2026-10-23）。
///
/// 用户页与电费卡片共用；居中、纯白底、20 圆角、右上角 ×。
/// 「宿舍楼」用 Flutter 原生 Autocomplete：输入即过滤、点选回填。
Future<DormInfo?> showDormDialog(
  BuildContext context, {
  DormInfo? current,
}) {
  return showDialog<DormInfo>(
    context: context,
    builder: (_) => _DormDialog(current: current),
  );
}

class _DormDialog extends StatefulWidget {
  const _DormDialog({this.current});

  final DormInfo? current;

  @override
  State<_DormDialog> createState() => _DormDialogState();
}

class _DormDialogState extends State<_DormDialog> {
  static const _ink = Color(0xFF111111);
  static const _sub = Color(0xFF9CA3AF);
  static const _line = Color(0xFFE8E8EE);

  final TextEditingController _room = TextEditingController();

  List<DormBuilding> _all = const [];
  DormBuilding? _picked;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _room.text = widget.current?.room ?? '';
    _load();
  }

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await DormService.buildings();
    if (!mounted) return;
    setState(() {
      _all = list;
      _loading = false;
      if (widget.current != null) {
        for (final b in list) {
          if (b.value == widget.current!.buildingValue) {
            _picked = b;
            break;
          }
        }
      }
    });
  }

  void _confirm() {
    final b = _picked;
    final room = _room.text.trim();
    if (b == null || room.isEmpty) return;
    Navigator.of(context).pop(DormInfo(
      feeitemid: b.feeitemid,
      buildingValue: b.value,
      buildingName: b.name,
      campus: b.campus,
      room: room,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final canConfirm = _picked != null && _room.text.trim().isNotEmpty;

    // 包一层去掉 viewInsets：输入法弹出时弹窗保持原位
    return MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _line),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('宿舍',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: _ink)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded,
                        size: 20, color: _sub),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _line),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('宿舍楼',
                      style: TextStyle(fontSize: 12, color: _ink)),
                  const SizedBox(height: 6),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('加载中…',
                          style: TextStyle(fontSize: 13, color: _sub)),
                    )
                  else
                    LayoutBuilder(
                      builder: (ctx, box) => Autocomplete<DormBuilding>(
                        initialValue: TextEditingValue(
                            text: _picked?.name ?? ''),
                        displayStringForOption: (b) => b.name,
                        optionsBuilder: (v) {
                          final q = v.text.trim();
                          if (q.isEmpty) return _all;
                          return _all.where((b) => b.name.contains(q));
                        },
                        onSelected: (b) {
                          if (!b.available) return;
                          setState(() => _picked = b);
                          FocusScope.of(ctx).unfocus();
                        },
                        fieldViewBuilder:
                            (ctx, ctl, focusNode, onFieldSubmitted) {
                          return TextField(
                            controller: ctl,
                            focusNode: focusNode,
                            style: const TextStyle(
                                fontSize: 13.5, color: _ink),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '搜索或选择宿舍楼',
                              hintStyle: const TextStyle(
                                  fontSize: 13, color: _sub),
                              suffixIcon: const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 20,
                                  color: _sub),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 13),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide:
                                    const BorderSide(color: _line),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide:
                                    const BorderSide(color: _line),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide:
                                    const BorderSide(color: _ink),
                              ),
                            ),
                          );
                        },
                        optionsViewBuilder: (ctx, onSelected, options) {
                          final list = options.toList();
                          return Align(
                            alignment: Alignment.topLeft,
                            child: Material(
                              color: Colors.white,
                              elevation: 3,
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                width: box.maxWidth,
                                // 只露三条，其余滚动
                                constraints:
                                    const BoxConstraints(maxHeight: 134),
                                decoration: BoxDecoration(
                                  border: Border.all(color: _line),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: ListView.builder(
                                  padding: EdgeInsets.zero,
                                  shrinkWrap: true,
                                  itemCount: list.length,
                                  itemBuilder: (_, i) {
                                    final b = list[i];
                                    final on = b.value == _picked?.value;
                                    return InkWell(
                                      onTap: () => onSelected(b),
                                      child: Container(
                                        height: 44,
                                        alignment: Alignment.centerLeft,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                        decoration: BoxDecoration(
                                          border: i == list.length - 1
                                              ? null
                                              : const Border(
                                                  bottom: BorderSide(
                                                      color: _line)),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                b.available
                                                    ? b.name
                                                    : '${b.name}（暂未开通）',
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  color: b.available
                                                      ? _ink
                                                      : _sub,
                                                  fontWeight: on
                                                      ? FontWeight.w600
                                                      : FontWeight.w400,
                                                ),
                                              ),
                                            ),
                                            if (on)
                                              const Icon(
                                                  Icons.check_rounded,
                                                  size: 16,
                                                  color: Color(0xFF111111)),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 14),
                  const Text('宿舍号',
                      style: TextStyle(fontSize: 12, color: _ink)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _room,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.text,
                    style: const TextStyle(fontSize: 13.5, color: _ink),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '例如 408',
                      hintStyle: const TextStyle(fontSize: 13, color: _sub),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 13),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _ink),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _line),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: canConfirm ? _confirm : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF111111),
                    disabledBackgroundColor: const Color(0xFFE5E7EB),
                    foregroundColor: Colors.white,
                    disabledForegroundColor: _sub,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('确定', style: TextStyle(fontSize: 14)),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    ),
    );
  }
}

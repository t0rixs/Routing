import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../viewmodels/map_view_model.dart';

/// マップ画面の上部に重ねて表示する日付フィルタチップ。
///
/// - ON/OFF チェックボックス（画像案の `☑️` 相当）
/// - `YYYY/MM/DD - YYYY/MM/DD` の期間表示
/// - タップすると Material の `showDateRangePicker` が開く
/// - デフォルトは「今日 - 今日」
class DateFilterChip extends StatelessWidget {
  const DateFilterChip({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, vm, _) {
        final bool enabled = vm.dateFilterEnabled;
        final DateTime today = DateTime.now();
        final DateTime start =
            vm.dateFilterStart ?? DateTime(today.year, today.month, today.day);
        final DateTime end =
            vm.dateFilterEnd ?? DateTime(today.year, today.month, today.day);

        final df = DateFormat('yyyy/MM/dd');
        final String label = '${df.format(start)} - ${df.format(end)}';

        return Material(
          color: enabled
              ? Colors.red.withValues(alpha: 0.85)
              : Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // チェックボックス（タップで ON/OFF のみ。日付ピッカーは開かない）
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    vm.setDateFilter(
                      enabled: !enabled,
                      start: start,
                      end: end,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      enabled
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
                // 日付テキスト（タップで範囲選択ピッカー）
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () async {
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2015),
                      lastDate: DateTime(today.year + 1, 12, 31),
                      initialDateRange:
                          DateTimeRange(start: start, end: end),
                      helpText: '日付で絞り込み',
                      saveText: '適用',
                      cancelText: 'キャンセル',
                      confirmText: 'OK',
                    );
                    if (picked != null) {
                      vm.setDateFilter(
                        enabled: true,
                        start: picked.start,
                        end: picked.end,
                      );
                    }
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

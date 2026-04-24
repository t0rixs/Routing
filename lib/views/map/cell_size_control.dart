import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodels/map_view_model.dart';

/// セル描画サイズの固定 / 解除を切り替えるトグルボタン。
///
/// - 自動モード時  : 白背景＋青アイコン（lock_open）。押すと現在の cellZ で固定。
/// - 手動（固定）時: 青背景＋白文字（"Z{n}"）。押すと自動に戻す。
///
/// ロック中でもボタンサイズを大きくしないよう、両方とも `mini` FAB を使い、
/// 数字は `Text` で表示する（アイコンは不要）。
class CellSizeControl extends StatelessWidget {
  const CellSizeControl({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, viewModel, _) {
        final bool locked = viewModel.isManualCellSize;
        final cs = Theme.of(context).colorScheme;
        return FloatingActionButton(
          heroTag: 'cellSizeToggle',
          mini: true,
          backgroundColor: locked ? cs.primary : cs.surface,
          foregroundColor: locked ? cs.onPrimary : cs.primary,
          tooltip: locked
              ? 'Z${viewModel.manualCellZ}（タップで自動に戻す）'
              : '現在の拡大率でセルサイズを固定',
          onPressed: () {
            if (locked) {
              viewModel.setAutoCellSize();
            } else {
              // 自動モードのタイル/プリフェッチ計算は `zoom.floor()` を使うため、
              // 固定時も同じ floor 値を採用しないとロック前後でセルサイズが
              // 1 段ぶん変わって見える（ズーム 13.7 → round で 14、floor で 13）。
              final currentZ =
                  viewModel.cameraPosition.zoom.floor().clamp(3, 14);
              viewModel.setManualCellSize(currentZ);
            }
          },
          child: locked
              ? Text(
                  'Z${viewModel.manualCellZ}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                )
              : const Icon(Icons.lock_open, size: 20),
        );
      },
    );
  }
}

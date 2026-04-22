import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodels/map_view_model.dart';

/// セル描画サイズの固定/解除を切り替えるトグルボタン。
///
/// - 自動モード時: 「固定」アイコン。押すと現在の自動 cellZ（map zoom）で固定
/// - 手動（固定）モード時: 「固定解除」アイコン＋現在の Z 値。押すと自動に戻る
class CellSizeControl extends StatelessWidget {
  const CellSizeControl({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, viewModel, _) {
        if (viewModel.isManualCellSize) {
          return _buildLockedButton(context, viewModel);
        }
        return _buildUnlockedButton(context, viewModel);
      },
    );
  }

  Widget _buildUnlockedButton(BuildContext context, MapViewModel viewModel) {
    return FloatingActionButton.small(
      heroTag: 'cellSizeToggle',
      tooltip: '現在の拡大率でセルサイズを固定',
      onPressed: () {
        final currentZ = viewModel.cameraPosition.zoom.round().clamp(3, 14);
        viewModel.setManualCellSize(currentZ);
      },
      child: const Icon(Icons.lock_open),
    );
  }

  Widget _buildLockedButton(BuildContext context, MapViewModel viewModel) {
    return FloatingActionButton.extended(
      heroTag: 'cellSizeToggle',
      tooltip: '自動モードに戻す',
      onPressed: () => viewModel.setAutoCellSize(),
      icon: const Icon(Icons.lock),
      label: Text('Z${viewModel.manualCellZ}'),
    );
  }
}

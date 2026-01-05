import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../../viewmodels/map_view_model.dart';
import 'package:intl/intl.dart';

class MapWidget extends StatelessWidget {
  const MapWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, viewModel, child) {
        return Stack(
          children: [
            GoogleMap(
              initialCameraPosition: viewModel.cameraPosition,
              onMapCreated: viewModel.onMapCreated,
              onCameraMove: viewModel.onCameraMove,
              onTap: (latLng) async {
                // タップしたセルの情報を取得
                final cell = await viewModel.onTap(latLng);
                if (context.mounted && cell != null) {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Cell Info'),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Value: ${cell.val}'),
                          Text('Lat Index: ${cell.lat}'),
                          Text('Lng Index: ${cell.lng}'),
                          if (cell.p1 != null && cell.p1! > 0)
                            Text(
                                '初回更新: ${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(cell.p1!))}'),
                          Text(
                              '最終更新時間: ${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(cell.tm))}'),
                          GestureDetector(
                            onTap: () {
                              Navigator.of(ctx).pop(); // ダイアログを閉じる
                              viewModel.startDeleteSectionMode(cell);
                            },
                            child: const Padding(
                              padding: EdgeInsets.only(top: 8.0),
                              child: Text('区間削除',
                                  style: TextStyle(color: Colors.blue)),
                            ),
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(
                          child: const Text('Close'),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                  );
                }
              },
              tileOverlays:
                  viewModel.tileOverlay != null ? {viewModel.tileOverlay!} : {},
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: true,
              mapToolbarEnabled: false,
            ),
            if (viewModel.isDeleteSectionMode)
              Positioned(
                top: 50,
                left: 20,
                right: 20,
                child: Card(
                  color: Colors.white.withOpacity(0.9),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          viewModel.isDeleteReady
                              ? '削除範囲が選択されました'
                              : '区間の終点を選択してください',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 10),
                        if (viewModel.isDeleteReady)
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white),
                            child: Text(
                                '削除実行 (${viewModel.highlightCells.length} cells)'),
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('区間削除'),
                                  content: Text(
                                      '選択された範囲のデータを削除しますか？\n対象セル数: ${viewModel.highlightCells.length}'),
                                  actions: [
                                    TextButton(
                                        child: const Text('キャンセル'),
                                        onPressed: () =>
                                            Navigator.of(ctx).pop()),
                                    TextButton(
                                        child: const Text('実行',
                                            style:
                                                TextStyle(color: Colors.red)),
                                        onPressed: () async {
                                          Navigator.of(ctx)
                                              .pop(); // 確認ダイアログを閉じる

                                          // 処理中ダイアログを表示
                                          showDialog(
                                            context: context,
                                            barrierDismissible: false,
                                            builder: (BuildContext context) {
                                              return const Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              );
                                            },
                                          );

                                          // 削除実行
                                          await viewModel
                                              .executeDeleteSection();

                                          if (context.mounted) {
                                            Navigator.of(context)
                                                .pop(); // 処理中ダイアログを閉じる
                                          }

                                          if (context.mounted) {
                                            // 完了ダイアログを表示
                                            showDialog(
                                              context: context,
                                              builder: (ctx) => AlertDialog(
                                                title: const Text('削除完了'),
                                                content:
                                                    const Text('区間の削除が完了しました。'),
                                                actions: [
                                                  TextButton(
                                                    child: const Text('OK'),
                                                    onPressed: () =>
                                                        Navigator.of(ctx).pop(),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                        }),
                                  ],
                                ),
                              );
                            },
                          ),
                        TextButton(
                          child: const Text('キャンセル'),
                          onPressed: () => viewModel.cancelDeleteSectionMode(),
                        )
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

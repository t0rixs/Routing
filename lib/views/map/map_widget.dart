import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../../viewmodels/map_view_model.dart';
import 'package:intl/intl.dart';
import 'cell_size_control.dart';

class MapWidget extends StatefulWidget {
  const MapWidget({super.key});

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  MapViewModel? _mapViewModel;
  GoogleMapController? _controller;
  int _lastFollowTick = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mapViewModel == null) {
      _mapViewModel = context.read<MapViewModel>();
      _lastFollowTick = _mapViewModel!.followTick;
      _mapViewModel!.addListener(_onViewModelChanged);
    }
  }

  @override
  void dispose() {
    _mapViewModel?.removeListener(_onViewModelChanged);
    _mapViewModel?.disposeLocationRecording();
    super.dispose();
  }

  /// follow モード中に現在地が更新された場合、カメラを追従させる。
  void _onViewModelChanged() {
    final vm = _mapViewModel;
    if (vm == null) return;
    if (vm.followTick != _lastFollowTick) {
      _lastFollowTick = vm.followTick;
      final pos = vm.lastKnownPosition;
      if (vm.followUser && pos != null && _controller != null) {
        _controller!.animateCamera(CameraUpdate.newLatLng(pos));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, viewModel, child) {
        return Stack(
          children: [
            GoogleMap(
              initialCameraPosition: viewModel.cameraPosition,
              onMapCreated: (controller) {
                _controller = controller;
                viewModel.onMapCreated(controller);
              },
              onCameraMove: viewModel.onCameraMove,
              onCameraIdle: () async {
                viewModel.onCameraIdle();
                // ビューポート範囲を取得して shard プリフェッチを起動する。
                // 続けて要求される getTile が DB に行かずキャッシュヒットするため、
                // ズーム変更直後の描画時間を大きく短縮できる。
                try {
                  final controller = _controller;
                  if (controller != null) {
                    final bounds = await controller.getVisibleRegion();
                    viewModel.requestViewportPrefetch(bounds);
                  }
                } catch (_) {}
              },
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
              myLocationButtonEnabled: true,
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
                                      '選択された範囲のデータを削除しますか？\nこの操作は取り消せません。\n対象セル数: ${viewModel.highlightCells.length}'),
                                  actions: [
                                    TextButton(
                                        child: const Text('キャンセル'),
                                        onPressed: () =>
                                            Navigator.of(ctx).pop()),
                                    TextButton(
                                        child: const Text('実行',
                                            style:
                                                TextStyle(color: Colors.red)),
                                        onPressed: () {
                                          Navigator.of(ctx)
                                              .pop(); // 確認ダイアログを閉じる

                                          // 処理中ダイアログを表示
                                          showDialog(
                                            context: context,
                                            barrierDismissible: false,
                                            builder: (BuildContext context) {
                                              return _ProgressDialogContent(
                                                viewModel: viewModel,
                                              );
                                            },
                                          );
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
            const Positioned(
              bottom: 16,
              left: 16,
              child: CellSizeControl(),
            ),
            Positioned(
              // Scaffold 側の menu FAB と重ならないように上に積む
              bottom: 80,
              right: 16,
              child: FloatingActionButton(
                heroTag: 'followUserFab',
                mini: true,
                backgroundColor:
                    viewModel.followUser ? Colors.blue : Colors.white,
                foregroundColor:
                    viewModel.followUser ? Colors.white : Colors.blue,
                tooltip: viewModel.followUser ? '追従中（タップで解除）' : '現在地に追従',
                onPressed: () {
                  viewModel.toggleFollowUser();
                  final pos = viewModel.lastKnownPosition;
                  if (viewModel.followUser && pos != null) {
                    _controller?.animateCamera(CameraUpdate.newLatLng(pos));
                  }
                },
                child: Icon(
                  viewModel.followUser
                      ? Icons.gps_fixed
                      : Icons.gps_not_fixed,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ProgressDialogContent extends StatefulWidget {
  final MapViewModel viewModel;
  const _ProgressDialogContent({required this.viewModel});

  @override
  State<_ProgressDialogContent> createState() => _ProgressDialogContentState();
}

class _ProgressDialogContentState extends State<_ProgressDialogContent> {
  int _current = 0;
  int _total = 1;

  @override
  void initState() {
    super.initState();
    _startDeletion();
  }

  Future<void> _startDeletion() async {
    _total = widget.viewModel.highlightCells.length;
    if (_total == 0) _total = 1;

    await widget.viewModel.executeDeleteSection(
      onProgress: (current, total) {
        if (mounted) {
          setState(() {
            _current = current;
            _total = total;
          });
        }
      },
    );

    if (mounted) {
      Navigator.of(context).pop(); // Close progress dialog

      // Show completion dialog
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('削除完了'),
          content: const Text('区間の削除が完了しました。'),
          actions: [
            TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Prevent division by zero
    double progress = (_total > 0) ? _current / _total : 0.0;

    return AlertDialog(
      title: const Text('削除実行中'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 10),
          Text('$_current / $_total'),
        ],
      ),
    );
  }
}

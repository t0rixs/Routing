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
    // GoogleMap は Consumer の外に置く。
    // Consumer で包むと `notifyListeners()` (GPS 1Hz / follow tick / delete
    // mode 切替等) 毎に GoogleMap が rebuild され、プラットフォームビューの
    // ジェスチャ処理と競合して指追従が遅れていた。
    // tileOverlay だけを Selector で監視し、必要なときだけ GoogleMap に
    // 新しい overlay を渡す（旧 overlay 参照が同じなら Selector 自体が
    // rebuild しないので GoogleMap も動かない）。
    final vm = _mapViewModel ?? context.read<MapViewModel>();
    return Stack(
      children: [
        Selector<MapViewModel, TileOverlay?>(
          selector: (_, v) => v.tileOverlay,
          builder: (context, tileOverlay, _) {
            return GoogleMap(
              initialCameraPosition: vm.cameraPosition,
              onMapCreated: (controller) {
                _controller = controller;
                vm.onMapCreated(controller);
              },
              onCameraMoveStarted: vm.onCameraMoveStarted,
              onCameraMove: vm.onCameraMove,
              onCameraIdle: () async {
                vm.onCameraIdle();
                // ビューポート範囲を取得して shard プリフェッチを起動する。
                // 続けて要求される getTile が DB に行かずキャッシュヒットするため、
                // ズーム変更直後の描画時間を大きく短縮できる。
                try {
                  final controller = _controller;
                  if (controller != null) {
                    final bounds = await controller.getVisibleRegion();
                    vm.requestViewportPrefetch(bounds);
                  }
                } catch (_) {}
              },
              onTap: (latLng) => _handleMapTap(context, vm, latLng),
              tileOverlays:
                  tileOverlay != null ? {tileOverlay} : const <TileOverlay>{},
              myLocationEnabled: true,
              myLocationButtonEnabled: true,
              zoomControlsEnabled: false,
              compassEnabled: true,
              mapToolbarEnabled: false,
            );
          },
        ),
        // 削除モード UI は専用の Consumer で包む。
        // 状態変化は稀なので rebuild コストは無視できる。
        Consumer<MapViewModel>(
          builder: (context, v, _) {
            if (!v.isDeleteSectionMode) return const SizedBox.shrink();
            return _DeleteSectionOverlay(viewModel: v);
          },
        ),
        const Positioned(
          bottom: 16,
          left: 16,
          child: CellSizeControl(),
        ),
        // Follow ボタンも独立させる。GoogleMap は rebuild されない。
        Positioned(
          bottom: 80,
          right: 16,
          child: Consumer<MapViewModel>(
            builder: (context, v, _) {
              return FloatingActionButton(
                heroTag: 'followUserFab',
                mini: true,
                backgroundColor: v.followUser ? Colors.blue : Colors.white,
                foregroundColor: v.followUser ? Colors.white : Colors.blue,
                tooltip: v.followUser ? '追従中（タップで解除）' : '現在地に追従',
                onPressed: () {
                  v.toggleFollowUser();
                  final pos = v.lastKnownPosition;
                  if (v.followUser && pos != null) {
                    _controller?.animateCamera(CameraUpdate.newLatLng(pos));
                  }
                },
                child: Icon(
                  v.followUser ? Icons.gps_fixed : Icons.gps_not_fixed,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _handleMapTap(
      BuildContext context, MapViewModel viewModel, LatLng latLng) async {
    final cell = await viewModel.onTap(latLng);
    if (!context.mounted || cell == null) return;
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
                Navigator.of(ctx).pop();
                viewModel.startDeleteSectionMode(cell);
              },
              child: const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text('区間削除', style: TextStyle(color: Colors.blue)),
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
}

class _DeleteSectionOverlay extends StatelessWidget {
  const _DeleteSectionOverlay({required this.viewModel});
  final MapViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 50,
      left: 20,
      right: 20,
      child: Card(
        color: Colors.white.withValues(alpha: 0.9),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                viewModel.isDeleteReady ? '削除範囲が選択されました' : '区間の終点を選択してください',
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
                              onPressed: () => Navigator.of(ctx).pop()),
                          TextButton(
                              child: const Text('実行',
                                  style: TextStyle(color: Colors.red)),
                              onPressed: () {
                                Navigator.of(ctx).pop();
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

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../../generated/l10n/app_localizations.dart';
import '../../viewmodels/map_view_model.dart';
import 'package:intl/intl.dart';
import 'cell_size_control.dart';
import '../common/stats_detail_screen.dart';
import '../common/date_filter_chip.dart';

class MapWidget extends StatefulWidget {
  const MapWidget({super.key});

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  MapViewModel? _mapViewModel;
  GoogleMapController? _controller;
  int _lastFollowTick = 0;
  int _lastStyleTick = -1;

  /// 画面上のマップ操作 FAB 群を展開しているかどうか。
  /// `false` の時は menu FAB のみを表示し、他のボタン（follow / style /
  /// resetBearing / settings）は非表示にする。
  bool _fabExpanded = false;

  /// 起動時に SharedPreferences からのカメラ位置ロードを待つ Future。
  /// 完了するまで GoogleMap を描画しないことで、`initialCameraPosition` に
  /// 確実に保存値（または現在地）を渡す。
  Future<CameraPosition>? _initialCameraFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mapViewModel == null) {
      _mapViewModel = context.read<MapViewModel>();
      _lastFollowTick = _mapViewModel!.followTick;
      _lastStyleTick = _mapViewModel!.mapStyleTick;
      _mapViewModel!.addListener(_onViewModelChanged);
      _initialCameraFuture = _mapViewModel!.initializeCameraPosition();
    }
  }

  @override
  void dispose() {
    _mapViewModel?.removeListener(_onViewModelChanged);
    _mapViewModel?.disposeLocationRecording();
    super.dispose();
  }

  /// follow モード中に現在地が更新された場合、カメラを追従させる。
  /// ベースマップのスタイル変更も tick 経由で監視し、都度適用する。
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
    if (vm.mapStyleTick != _lastStyleTick) {
      _lastStyleTick = vm.mapStyleTick;
      _applyMapStyle();
    }
  }

  void _applyMapStyle() {
    final vm = _mapViewModel;
    final ctrl = _controller;
    if (vm == null || ctrl == null) return;
    // setMapStyle(null) でデフォルトに戻せる。失敗しても致命的ではない。
    // ignore: deprecated_member_use
    ctrl.setMapStyle(vm.mapStyleJson).catchError((_) {});
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
    return FutureBuilder<CameraPosition>(
      future: _initialCameraFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          // 復元処理中は無地で隠す。スピナーは出さず、準備完了後に自然に
          // マップ・セル数 HUD が現れるようにする。
          return const ColoredBox(color: Colors.white);
        }
        final initialPos = snapshot.data!;
        return Stack(
          children: [
            Selector<MapViewModel, (TileOverlay?, MapType, bool)>(
              selector: (_, v) =>
                  (v.tileOverlay, v.googleMapType, v.myLocationVisible),
              builder: (context, data, _) {
                final tileOverlay = data.$1;
                final mapType = data.$2;
                final myLocVisible = data.$3;
                return GoogleMap(
                  initialCameraPosition: initialPos,
                  onMapCreated: (controller) {
                    _controller = controller;
                    vm.onMapCreated(controller);
                    // 初回スタイル適用（SharedPreferences 読み込み完了済みの
                    // スタイルを反映）。非同期に実行して rebuild フレームを汚さない。
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _applyMapStyle();
                    });
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
                  tileOverlays: tileOverlay != null
                      ? {tileOverlay}
                      : const <TileOverlay>{},
                  myLocationEnabled: myLocVisible,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  // ネイティブコンパスは位置変更不可のため無効化。
                  // 代わりに自前の回転するコンパス FAB を表示する。
                  compassEnabled: false,
                  mapToolbarEnabled: false,
                  mapType: mapType,
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
            // 画面上部 HUD: 重複なしセル数 / 重複ありセル数（val 総和）。白文字のみ。
            const Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: _StatsHud(),
            ),
            // 日付フィルタチップ（位置は画面下中央固定、メニュー展開時のみ表示）。
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: _ExpandableFabSlot(
                    expanded: _fabExpanded,
                    child: const DateFilterChip(),
                  ),
                ),
              ),
            ),
            // ========== メニュー FAB + 円弧配置のサブボタン群 ==========
            // 画面右端（垂直は親 Stack の 70% 位置）に配置した menu FAB を
            // 中心に、半径 80px の円弧上にサブボタンを並べる（角度: 90°〜270°）。
            //
            // - 90°  (真上)  : follow
            // - 135° (左上)  : reset bearing（必要時のみ可視）
            // - 180° (真左)  : map style
            // - 225° (左下)  : settings
            // - 270° (真下)  : cell size lock
            //
            // 各サブボタンは `_ExpandableFabSlot` でラップし、メニュー展開時
            // または各自のアクティブ条件を満たす時にフェード＋スケールで表示。
            //
            // `LayoutBuilder` で Stack 実寸を取ってから中心 Y を計算するのは、
            // 広告バナーなどにより `MediaQuery.sizeOf(context).height` と
            // Stack の実高さがずれることがあるため（ずれると弧の中心と
            // menu FAB の中心が合わなくなる）。
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    clipBehavior: Clip.none,
                    children: _buildMapActionFabs(context, constraints),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// メニュー FAB を中心とする円弧配置のサブボタン群を組み立てる。
  ///
  /// 配置: Stack 実高さの 70% の位置に menu FAB 中心を置き、その周囲の
  /// 半径 80px 円弧上へ角度 90°, 135°, 180°, 225°, 270° の位置にサブボタンを置く。
  /// 中心の menu FAB も同時にここで配置する。
  List<Widget> _buildMapActionFabs(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    // Stack 実高さ（広告バナー分を除いた領域）を基準にする。
    final double stackHeight = constraints.maxHeight;
    // Stack 下から 30% の位置（＝上から 70%）にメニュー FAB を配置する。
    final double centerY = stackHeight * 0.7;
    // menu FAB（56x56）を画面右端に。top = centerY - 28 でボタン中心が centerY に一致。
    final double menuFabTop = centerY - 28;
    const double menuFabRight = 16;

    // サブボタン（mini FAB: 40x40）の位置計算。
    // menu FAB 中心は画面右から 44px (=16+28) 入った位置、垂直は centerY。
    // mini FAB の半径は 20 なので、「mini FAB 中心 = menu FAB 中心 ± r*(cos, sin)」
    // となるよう、right/top を以下で求める:
    //   mini FAB right 端基準 = 44 - r*cos - 20 = 24 - r*cos
    //   mini FAB top          = centerY - r*sin - 20
    const double radius = 80.0;
    ({double right, double top}) arcPos(double degrees) {
      final double rad = degrees * math.pi / 180.0;
      final double dx = radius * math.cos(rad);
      final double dy = -radius * math.sin(rad);
      return (right: 24 - dx, top: centerY + dy - 20);
    }

    final follow = arcPos(90); // 真上
    // settings / reset は位置を交換済み。settings は固定 225°、reset は動的。
    final settings = arcPos(225); // 左下
    final style = arcPos(180); // 真左
    final cellLock = arcPos(270); // 真下

    return [
      // follow FAB: 追従 ON 中はメニュー折り畳み時でも表示。
      Positioned(
        top: follow.top,
        right: follow.right,
        child: Consumer<MapViewModel>(
          builder: (context, v, _) {
            final cs = Theme.of(context).colorScheme;
            return _ExpandableFabSlot(
              expanded: _fabExpanded || v.followUser,
              child: FloatingActionButton(
                heroTag: 'followUserFab',
                mini: true,
                backgroundColor: v.followUser ? cs.primary : cs.surface,
                foregroundColor: v.followUser ? cs.onPrimary : cs.primary,
                tooltip: v.followUser ? AppLocalizations.of(context)!.tooltipFollowingOn : AppLocalizations.of(context)!.tooltipFollowingOff,
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
              ),
            );
          },
        ),
      ),
      // settings FAB: メニュー展開時のみ表示、Drawer を開く。
      Positioned(
        top: settings.top,
        right: settings.right,
        child: _ExpandableFabSlot(
          expanded: _fabExpanded,
          child: Builder(
            builder: (context) {
              final cs = Theme.of(context).colorScheme;
              return FloatingActionButton(
                heroTag: 'settingsFab',
                mini: true,
                backgroundColor: cs.surface,
                foregroundColor: cs.primary,
                tooltip: AppLocalizations.of(context)!.tooltipMenu,
                onPressed: () {
                  Scaffold.of(context).openDrawer();
                },
                child: const Icon(Icons.settings),
              );
            },
          ),
        ),
      ),
      // map style FAB: メニュー展開時のみ表示。
      Positioned(
        top: style.top,
        right: style.right,
        child: _ExpandableFabSlot(
          expanded: _fabExpanded,
          child: Selector<MapViewModel, MapBaseStyle>(
            selector: (_, v) => v.mapBaseStyle,
            builder: (context, currentStyle, _) {
              IconData icon;
              String tooltip;
              final lTip = AppLocalizations.of(context)!;
              switch (currentStyle) {
                case MapBaseStyle.satellite:
                  icon = Icons.satellite_alt;
                  tooltip = lTip.tooltipMapSatellite;
                  break;
                case MapBaseStyle.blank:
                  icon = Icons.crop_square;
                  tooltip = lTip.tooltipMapBlank;
                  break;
                case MapBaseStyle.standard:
                case MapBaseStyle.dark:
                  icon = Icons.map;
                  tooltip = lTip.tooltipMapStandard;
                  break;
              }
              final cs = Theme.of(context).colorScheme;
              return FloatingActionButton(
                heroTag: 'mapStyleCycleFab',
                mini: true,
                backgroundColor: cs.surface,
                foregroundColor: cs.primary,
                tooltip: tooltip,
                onPressed: () {
                  context.read<MapViewModel>().cycleMapBaseStyle();
                },
                child: Icon(icon),
              );
            },
          ),
        ),
      ),
      // reset bearing FAB: bearing/tilt != 0 の時、またはメニュー展開時に表示。
      // 位置は常に 135°（左上）固定で、settings / style と同じく fade+scale のみ。
      Selector<MapViewModel, (double, double)>(
        selector: (_, v) => (
          v.cameraPosition.bearing,
          v.cameraPosition.tilt,
        ),
        builder: (context, data, _) {
          final bearing = data.$1;
          final tilt = data.$2;
          final bool needsReset = bearing.abs() > 0.5 || tilt.abs() > 0.5;
          // reset は常に 135° に固定し、展開時/追従 ON/OFF に関わらず位置は
          // 動かさない。可視化のみ `_ExpandableFabSlot` の fade+scale で行う
          // ことで、他のサブボタン（settings / style / cellLock）と統一する。
          const double angle = 135.0;
          return _ArcAnimatedPositioned(
            angle: angle,
            radius: 80.0,
            centerY: centerY,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: _ExpandableFabSlot(
              expanded: _fabExpanded || needsReset,
              child: Builder(builder: (context) {
                final cs = Theme.of(context).colorScheme;
                return FloatingActionButton(
                heroTag: 'resetBearingFab',
                mini: true,
                backgroundColor: cs.surface,
                foregroundColor: cs.primary,
                tooltip: AppLocalizations.of(context)!.tooltipResetCamera,
                onPressed: () {
                  final vm = context.read<MapViewModel>();
                  final cp = vm.cameraPosition;
                  _controller?.animateCamera(
                    CameraUpdate.newCameraPosition(
                      CameraPosition(
                        target: cp.target,
                        zoom: cp.zoom,
                        bearing: 0,
                        tilt: 0,
                      ),
                    ),
                  );
                },
                child: _CompassRotation(
                  bearing: bearing,
                  duration: const Duration(milliseconds: 120),
                  child: const Icon(Icons.navigation),
                ),
              );
              }),
            ),
          );
        },
      ),
      // cell size lock FAB: メニュー展開時、またはロック中は常時表示。
      Positioned(
        top: cellLock.top,
        right: cellLock.right,
        child: Selector<MapViewModel, bool>(
          selector: (_, v) => v.isManualCellSize,
          builder: (context, locked, _) {
            return _ExpandableFabSlot(
              expanded: _fabExpanded || locked,
              child: const CellSizeControl(),
            );
          },
        ),
      ),
      // 中心の menu FAB: 単タップでサブボタン群のトグル、長押しで達成度画面。
      Positioned(
        top: menuFabTop,
        right: menuFabRight,
        child: Builder(
          builder: (context) {
            final cs = Theme.of(context).colorScheme;
            return Tooltip(
          message: _fabExpanded ? AppLocalizations.of(context)!.fabClose : AppLocalizations.of(context)!.fabMenu,
          child: Material(
            color: cs.surface,
            elevation: 6,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                setState(() => _fabExpanded = !_fabExpanded);
              },
              onLongPress: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const StatsDetailScreen(),
                  ),
                );
              },
              child: SizedBox(
                width: 56,
                height: 56,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) => RotationTransition(
                      turns: Tween<double>(begin: 0.75, end: 1.0).animate(anim),
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: Icon(
                      _fabExpanded ? Icons.close : Icons.menu,
                      color: cs.primary,
                      key: ValueKey<bool>(_fabExpanded),
                    ),
                  ),
                ),
              ),
            ),
          ),
            );
          },
        ),
      ),
    ];
  }

  Future<void> _handleMapTap(
      BuildContext context, MapViewModel viewModel, LatLng latLng) async {
    final cell = await viewModel.onTap(latLng);
    if (!context.mounted || cell == null) return;
    showDialog(
      context: context,
      builder: (ctx) {
        final l = AppLocalizations.of(ctx)!;
        return AlertDialog(
          title: const Text('Cell Info'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Value: ${cell.val}'),
              Text('Lat Index: ${cell.lat}'),
              Text('Lng Index: ${cell.lng}'),
              if (cell.p1 != null && cell.p1! > 0)
                Text(l.cellInfoFirst(
                    DateFormat('yyyy/MM/dd HH:mm').format(
                        DateTime.fromMillisecondsSinceEpoch(cell.p1!)))),
              Text(l.cellInfoLast(
                  DateFormat('yyyy/MM/dd HH:mm').format(
                      DateTime.fromMillisecondsSinceEpoch(cell.tm)))),
              GestureDetector(
                onTap: () {
                  Navigator.of(ctx).pop();
                  viewModel.startDeleteSectionMode(cell);
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(l.deleteSection,
                      style: const TextStyle(color: Colors.blue)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              child: Text(l.ok),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        );
      },
    );
  }
}

class _DeleteSectionOverlay extends StatelessWidget {
  const _DeleteSectionOverlay({required this.viewModel});
  final MapViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
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
                viewModel.isDeleteReady ? l.deleteSelected : l.deleteSelectEnd,
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
                      l.deleteExecuteCells(viewModel.highlightCells.length)),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(l.deleteSectionConfirmTitle),
                        content: Text(l.deleteSectionConfirmBody(
                            viewModel.highlightCells.length)),
                        actions: [
                          TextButton(
                              child: Text(l.cancel),
                              onPressed: () => Navigator.of(ctx).pop()),
                          TextButton(
                              child: Text(l.execute,
                                  style: const TextStyle(color: Colors.red)),
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
                child: Text(l.cancel),
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
        builder: (ctx) {
          final l = AppLocalizations.of(ctx)!;
          return AlertDialog(
            title: Text(l.deleteDoneTitle),
            content: Text(l.deleteDoneBody),
            actions: [
              TextButton(
                child: Text(l.ok),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          );
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Prevent division by zero
    double progress = (_total > 0) ? _current / _total : 0.0;

    return AlertDialog(
      title: Text(AppLocalizations.of(context)!.deleteRunningTitle),
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

/// 展開状態に応じてフェード＋縮小し、折り畳み中はヒットテストも無効化する
/// FAB スロット。menu FAB で画面上のボタン群を一括表示 / 非表示するために
/// 使う。
class _ExpandableFabSlot extends StatelessWidget {
  const _ExpandableFabSlot({
    required this.expanded,
    required this.child,
  });

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !expanded,
      child: AnimatedOpacity(
        opacity: expanded ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: AnimatedScale(
          scale: expanded ? 1.0 : 0.8,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }
}

/// 画面上部に表示する累計統計（白文字のみ）。
/// `{重複なしセル数}cells/{重複ありセル数}cells` の形式。
/// 背景は `_TopGradientBackdrop` で別レイヤとして描く。
class _StatsHud extends StatelessWidget {
  const _StatsHud();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Consumer<MapViewModel>(
          builder: (context, vm, _) {
            final f = NumberFormat.decimalPattern();
            final text =
                '${f.format(vm.totalUniqueCells)}cells/${f.format(vm.totalVisits)}cells';
            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const StatsDetailScreen(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                      // 背景なしでも見えるよう影でコントラストを確保。
                      shadows: [
                        Shadow(blurRadius: 4, color: Colors.black),
                        Shadow(blurRadius: 8, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 地図 bearing に応じてアイコンを回転させるラッパ。
///
/// `AnimatedRotation` に `turns: -bearing/360` をそのまま渡すと、bearing が
/// 1° ↔ 359° を跨いだとき turns の差分が約 ±1.0 になり、ほぼ 1 周ぶん
/// 回転してしまう。本ウィジェットは内部に「現在表示中の turns 値」を保持し、
/// 新しい目標値との差分を (-0.5, 0.5] に正規化して加算することで、
/// 常に最短経路で回転させる。
class _CompassRotation extends StatefulWidget {
  const _CompassRotation({
    required this.bearing,
    required this.child,
    this.duration = const Duration(milliseconds: 120),
    this.curve = Curves.easeOut,
  });

  final double bearing; // degrees, positive clockwise
  final Widget child;
  final Duration duration;
  final Curve curve;

  @override
  State<_CompassRotation> createState() => _CompassRotationState();
}

class _CompassRotationState extends State<_CompassRotation> {
  late double _displayedTurns;

  @override
  void initState() {
    super.initState();
    _displayedTurns = -widget.bearing / 360.0;
  }

  @override
  void didUpdateWidget(_CompassRotation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bearing != oldWidget.bearing) {
      final double target = -widget.bearing / 360.0;
      // delta を (-0.5, 0.5] に正規化して最短経路を取る。
      double delta = target - _displayedTurns;
      delta = delta - delta.roundToDouble();
      _displayedTurns = _displayedTurns + delta;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: _displayedTurns,
      duration: widget.duration,
      curve: widget.curve,
      child: widget.child,
    );
  }
}

/// メニュー FAB を中心とした弧に沿って、子ウィジェットを動かす Positioned。
///
/// `AnimatedPositioned` は (top, right) を独立に線形補間するため、2 点間を
/// 直線で移動する。本ウィジェットは `angle` を補間し、毎フレーム極座標から
/// (top, right) を計算することで、円弧上を滑らかに遷移する。
class _ArcAnimatedPositioned extends StatefulWidget {
  const _ArcAnimatedPositioned({
    required this.angle,
    required this.radius,
    required this.centerY,
    required this.child,
    this.duration = const Duration(milliseconds: 240),
    this.curve = Curves.easeOut,
  });

  final double angle;
  final double radius;
  final double centerY;
  final Widget child;
  final Duration duration;
  final Curve curve;

  @override
  State<_ArcAnimatedPositioned> createState() => _ArcAnimatedPositionedState();
}

class _ArcAnimatedPositionedState extends State<_ArcAnimatedPositioned>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _angleAnim;
  late double _displayedAngle;

  @override
  void initState() {
    super.initState();
    _displayedAngle = widget.angle;
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _angleAnim = AlwaysStoppedAnimation<double>(_displayedAngle);
    _controller.addListener(() {
      setState(() {
        _displayedAngle = _angleAnim.value;
      });
    });
  }

  @override
  void didUpdateWidget(_ArcAnimatedPositioned oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.angle != oldWidget.angle) {
      _angleAnim = Tween<double>(
        begin: _displayedAngle,
        end: widget.angle,
      ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rad = _displayedAngle * math.pi / 180.0;
    // `arcPos` と同じ式: right = 24 - r*cos, top = centerY - r*sin - 20。
    final double right = 24 - widget.radius * math.cos(rad);
    final double top = widget.centerY - widget.radius * math.sin(rad) - 20;
    return Positioned(
      top: top,
      right: right,
      child: widget.child,
    );
  }
}

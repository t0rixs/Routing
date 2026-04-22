import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmap;
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/cell.dart';
import '../../viewmodels/map_view_model.dart';
import 'cell_size_control.dart';

class MapWidgetFlutterMap extends StatefulWidget {
  const MapWidgetFlutterMap({super.key});

  @override
  State<MapWidgetFlutterMap> createState() => _MapWidgetFlutterMapState();
}

class _MapWidgetFlutterMapState extends State<MapWidgetFlutterMap> {
  MapViewModel? _mapViewModel;
  final MapController _mapController = MapController();

  List<CellPolygon> _polygons = [];
  Timer? _throttleTimer;
  DateTime _lastFetchAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _pendingReload = false;
  static const Duration _throttleInterval = Duration(milliseconds: 250);

  bool _lastIsManual = false;
  int _lastManualZ = -1;
  int _lastTileRefreshCounter = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mapViewModel == null) {
      _mapViewModel = context.read<MapViewModel>();
      _lastIsManual = _mapViewModel!.isManualCellSize;
      _lastManualZ = _mapViewModel!.manualCellZ;
      _lastTileRefreshCounter = _mapViewModel!.tileRefreshCounter;
      _mapViewModel!.addListener(_onViewModelChanged);
    }
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    _mapViewModel?.removeListener(_onViewModelChanged);
    _mapViewModel?.disposeLocationRecording();
    super.dispose();
  }

  void _onViewModelChanged() {
    final vm = _mapViewModel;
    if (vm == null) return;
    if (vm.isManualCellSize != _lastIsManual ||
        vm.manualCellZ != _lastManualZ ||
        vm.tileRefreshCounter != _lastTileRefreshCounter) {
      _lastIsManual = vm.isManualCellSize;
      _lastManualZ = vm.manualCellZ;
      _lastTileRefreshCounter = vm.tileRefreshCounter;
      _scheduleReload();
    }
  }

  /// スロットリング: 移動中も最大 [_throttleInterval] ごとに描画を更新する。
  /// 末尾の移動にも追随するため、連続呼び出しが止まった後にも必ず 1 回走る。
  void _scheduleReload() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastFetchAt);

    if (elapsed >= _throttleInterval && _throttleTimer == null) {
      _loadPolygons();
      return;
    }

    _pendingReload = true;
    if (_throttleTimer != null) return;

    final wait = elapsed >= _throttleInterval
        ? Duration.zero
        : _throttleInterval - elapsed;
    _throttleTimer = Timer(wait, () {
      _throttleTimer = null;
      if (_pendingReload) {
        _pendingReload = false;
        _loadPolygons();
      }
    });
  }

  Future<void> _loadPolygons() async {
    final vm = _mapViewModel;
    if (vm == null) return;

    _lastFetchAt = DateTime.now();
    _pendingReload = false;

    final bounds = _mapController.camera.visibleBounds;
    final zoom = _mapController.camera.zoom.round();

    final polys = await vm.fetchCellPolygons(
      bounds.south,
      bounds.north,
      bounds.west,
      bounds.east,
      zoom,
    );

    if (mounted) {
      setState(() {
        _polygons = polys;
      });
    }

    // フェッチ完了直後もまだ移動が続いている可能性があるので、
    // ペンディングがあれば次のスロットで再描画する
    if (_pendingReload && _throttleTimer == null) {
      _throttleTimer = Timer(_throttleInterval, () {
        _throttleTimer = null;
        if (_pendingReload) {
          _pendingReload = false;
          _loadPolygons();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, viewModel, child) {
        final initial = viewModel.cameraPosition;
        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter:
                    LatLng(initial.target.latitude, initial.target.longitude),
                initialZoom: initial.zoom,
                minZoom: 3,
                maxZoom: 18,
                onTap: (tapPosition, point) async {
                  final cell = await viewModel.onTap(
                    gmap.LatLng(point.latitude, point.longitude),
                  );
                  if (!context.mounted || cell == null) return;
                  await showDialog(
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
                },
                onMapReady: () {
                  viewModel.refreshMap();
                  _loadPolygons();
                },
                onPositionChanged: (camera, hasGesture) {
                  viewModel.onCameraMove(
                    gmap.CameraPosition(
                      target: gmap.LatLng(
                        camera.center.latitude,
                        camera.center.longitude,
                      ),
                      zoom: camera.zoom,
                    ),
                  );
                  _scheduleReload();
                },
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager_nolabels/{z}/{x}/{y}{r}.png',
                  subdomains: const ['a', 'b', 'c', 'd'],
                  userAgentPackageName: 'com.mapping.routing',
                  maxNativeZoom: 19,
                  retinaMode: RetinaMode.isHighDensity(context),
                ),
                Builder(builder: (context) {
                  final int mapZoom =
                      _mapController.camera.zoom.round().clamp(3, 19);
                  final bool hideStroke =
                      viewModel.shouldHideCellStroke(mapZoom);
                  return PolygonLayer(
                    polygons: _polygons.map((cp) {
                      final points = [
                        LatLng(cp.south, cp.west),
                        LatLng(cp.south, cp.east),
                        LatLng(cp.north, cp.east),
                        LatLng(cp.north, cp.west),
                      ];
                      final double strokeWidth = cp.isHighlighted
                          ? 2.0
                          : (hideStroke ? 0.0 : 0.5);
                      return Polygon(
                        points: points,
                        color: cp.color.withValues(alpha: 0.6),
                        borderColor: cp.isHighlighted
                            ? Colors.red
                            : Colors.black.withValues(alpha: 0.3),
                        borderStrokeWidth: strokeWidth,
                      );
                    }).toList(),
                  );
                }),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                    TextSourceAttribution('CARTO'),
                  ],
                ),
              ],
            ),
            const Positioned(
              bottom: 16,
              left: 16,
              child: CellSizeControl(),
            ),
          ],
        );
      },
    );
  }
}

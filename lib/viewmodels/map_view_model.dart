import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/cell.dart';
import '../repositories/database_repository.dart';

/// マップの表示状態とデータロードを管理するViewModel
class MapViewModel extends ChangeNotifier {
  final DatabaseRepository _databaseRepository = DatabaseRepository();

  // 現在のカメラ位置
  CameraPosition _cameraPosition =
      const CameraPosition(target: LatLng(35.6895, 139.6917), zoom: 14);
  CameraPosition get cameraPosition => _cameraPosition;

  // TileOverlay
  TileOverlay? _tileOverlay;
  TileOverlay? get tileOverlay => _tileOverlay;

  // タイル更新用カウンタ to force refresh
  int _tileOverlayCounter = 0;

  void onMapCreated(GoogleMapController controller) {
    _refreshTileOverlay();
  }

  void onCameraMove(CameraPosition position) {
    _cameraPosition = position;
  }

  /// タイルオーバーレイを更新 (再描画)
  void _refreshTileOverlay() {
    if (_tileOverlayCounter > 1000) _tileOverlayCounter = 0;
    _tileOverlayCounter++;

    _tileOverlay = TileOverlay(
      tileOverlayId: TileOverlayId('heatmap_overlay_$_tileOverlayCounter'),
      tileProvider: _HeatmapTileProvider(this),
      transparency: 0.0,
      fadeIn: true,
    );
    notifyListeners();
  }

  /// 外部からリフレッシュを要求する
  void refreshMap() {
    _refreshTileOverlay();
  }

  // --- Helpers: Web Mercator forward + cell rect in this tile ---
  Point<double> latLngToWorldPixel(
      double latDeg, double lngDeg, int z, int ts) {
    final double n = pow(2, z).toDouble(); // 2^z tiles per axis
    // X: linear in longitude
    final double worldPixelX = ((lngDeg + 180.0) / 360.0) * n * ts.toDouble();
    // Y: Web Mercator (non-linear)
    final double latRad = latDeg * pi / 180.0;
    final double yTile = (1 - log(tan(pi / 4 + latRad / 2)) / pi) / 2 * n;
    final double worldPixelY = yTile * ts.toDouble();
    return Point(worldPixelX, worldPixelY);
  }

  /// タイルの画像データを生成して返すメソッド
  Future<Tile> getTile(int tileX, int tileY, int? zoomDesc) async {
    const int ts = 512;
    // debugPrint('getTile Spark: $tileX, $tileY, $zoomDesc');

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    if (zoomDesc == null) {
      return _finishTile(recorder, ts);
    }

    // Zoomレベルの決定: 3..14 にクランプ
    final int tileZ = zoomDesc;
    final int cellZ = tileZ.clamp(3, 14);

    // データを取得
    final cells =
        await _databaseRepository.fetchCells(tileZ, cellZ, tileX, tileY);

    if (cells.isEmpty) {
      return _finishTile(recorder, ts);
    }

    Rect cellRectInThisTile(int latIndex, int lngIndex) {
      final LatLngBounds b = _cellToLatLngBounds(cellZ, latIndex, lngIndex);
      final Point<double> sw = latLngToWorldPixel(
          b.southwest.latitude, b.southwest.longitude, tileZ, ts);
      final Point<double> ne = latLngToWorldPixel(
          b.northeast.latitude, b.northeast.longitude, tileZ, ts);

      // Convert to tile-local pixels (origin at this tile's top-left)
      final double pxW = sw.x - tileX * ts.toDouble();
      final double pyS = sw.y - tileY * ts.toDouble();
      final double pxE = ne.x - tileX * ts.toDouble();
      final double pyN = ne.y - tileY * ts.toDouble();

      final double left = min(pxW, pxE);
      final double top = min(pyN, pyS);
      final double width = (pxE - pxW).abs();
      final double height = (pyS - pyN).abs();
      return Rect.fromLTWH(left, top, width, height);
    }

    // 描画処理
    for (final cell in cells) {
      final Rect r = cellRectInThisTile(cell.lat, cell.lng);
      // Skip fully out-of-tile rects
      if (r.right <= 0 || r.bottom <= 0 || r.left >= ts || r.top >= ts) {
        continue;
      }

      final color = _calculateCellColor(cell.val, cellZ);
      final paintFill = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawRect(r, paintFill);

      // ストローク (枠線)
      final paintStroke = Paint()
        ..color = Colors.black.withValues(alpha: 0.3) // 色を変更 (例: 黒の半透明)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5;
      canvas.drawRect(r, paintStroke);
    }

    return _finishTile(recorder, ts);
  }

  Future<Tile> _finishTile(ui.PictureRecorder recorder, int ts) async {
    final picture = recorder.endRecording();
    final image = await picture.toImage(ts, ts);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return Tile(ts, ts, byteData!.buffer.asUint8List());
  }

  /// CellのLat/LngインデックスからLatLngBoundsを計算
  LatLngBounds _cellToLatLngBounds(int cellZ, int latIndex, int lngIndex) {
    // Zoom14基準で0.0002度
    final double cellSize = (0.0002 * pow(2, 14 - cellZ)).toDouble();
    final double south = latIndex * cellSize - 90.0;
    final double west = lngIndex * cellSize - 180.0;
    final double north = south + cellSize;
    final double east = west + cellSize;

    return LatLngBounds(
      southwest: LatLng(south, west),
      northeast: LatLng(north, east),
    );
  }

  /// セルの色を計算
  Color _calculateCellColor(int cellValue, int cellZ) {
    final maxValue = (14 * pow(2, 14 - cellZ)).floor();
    // clampして0割回避
    final safeMax = maxValue < 1 ? 1 : maxValue;
    final double ratio = cellValue.clamp(1, safeMax).toDouble() / safeMax;
    // ratio 0.0 -> Hue 255 (Blue/Purple)
    // ratio 1.0 -> Hue 0 (Red)
    final double hue = 255 - (ratio * 255);
    return HSVColor.fromAHSV(1.0, hue, 1.0, 0.8)
        .toColor()
        .withValues(alpha: 0.6); // 透過度調整
  }

  Future<Cell?> onTap(LatLng latLng) async {
    // タップした場所のcell情報を取得
    // Zoom 14 固定 (データは基本的に14で格納されているか、インポート時に14相当に補正されている前提)
    const int targetZ = 14;
    final double cellSize = (0.0002 * pow(2, 14 - targetZ)).toDouble();

    int latIndex = ((latLng.latitude + 90.0) / cellSize).floor();
    int lngIndex = ((latLng.longitude + 180.0) / cellSize).floor();

    debugPrint('onTap: $latLng -> Index($latIndex, $lngIndex)');

    return await _databaseRepository.getCell(targetZ, latIndex, lngIndex);
  }
}

/// GoogleMap用のTileProvider
class _HeatmapTileProvider implements TileProvider {
  final MapViewModel _viewModel;
  _HeatmapTileProvider(this._viewModel);

  @override
  Future<Tile> getTile(int x, int y, int? zoom) {
    return _viewModel.getTile(x, y, zoom);
  }
}

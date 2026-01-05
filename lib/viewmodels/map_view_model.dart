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

  // --- Delete Section Mode State ---
  bool isDeleteSectionMode = false;
  bool isDeleteReady = false;
  Cell? _deleteSectionStartCell;
  Set<Cell> _highlightCells = {};
  Set<Cell> get highlightCells => _highlightCells;
  // Cache for mult-zoom highlighting: Key=ZoomLevel, Value=Set of "lat_lng" strings
  Map<int, Set<String>> _highlightCache = {};

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

  // --- Delete Section Logic ---

  void startDeleteSectionMode(Cell cell) {
    isDeleteSectionMode = true;
    _deleteSectionStartCell = cell;
    isDeleteReady = false;
    _deleteSectionStartCell = cell;
    isDeleteReady = false;
    _highlightCells = {};
    _highlightCache.clear();
    _refreshTileOverlay(); // ハイライトクリアのため念のため
    notifyListeners();
  }

  void cancelDeleteSectionMode() {
    isDeleteSectionMode = false;
    _deleteSectionStartCell = null;
    isDeleteReady = false;
    _highlightCells = {};
    _highlightCache.clear();
    _refreshTileOverlay();
    notifyListeners();
  }

  Future<void> executeDeleteSection({Function(int, int)? onProgress}) async {
    if (_highlightCells.isEmpty) return;

    await _databaseRepository.deleteCells(_highlightCells.toList(),
        onProgress: onProgress);

    // 完了処理
    cancelDeleteSectionMode();
    _refreshTileOverlay();
  }

  Future<void> _handleDeleteSectionSelection(Cell cellB) async {
    final cellA = _deleteSectionStartCell!;

    // 比較候補
    final int atm = cellA.tm;
    // p1がnullまたは0以下の場合は比較対象外とする
    final int? ap1 = (cellA.p1 != null && cellA.p1! > 0) ? cellA.p1 : null;

    final int btm = cellB.tm;
    final int? bp1 = (cellB.p1 != null && cellB.p1! > 0) ? cellB.p1 : null;

    int diff(int? v1, int? v2) {
      if (v1 == null || v2 == null) return 9223372036854775807; // int64 max
      return (v1 - v2).abs();
    }

    // 4パターン計算
    final d1 = diff(atm, btm); // Atm - Btm
    final d2 = diff(atm, bp1); // Atm - Bp1
    final d3 = diff(ap1, btm); // Ap1 - Btm
    final d4 = diff(ap1, bp1); // Ap1 - Bp1

    // 最小を探す
    if (d1 <= d2 && d1 <= d3 && d1 <= d4) {
      debugPrint('Selected Range: Atm($atm) - Btm($btm) (Diff: $d1)');
      // startT, endT determined later
    } else if (d2 <= d1 && d2 <= d3 && d2 <= d4) {
      debugPrint('Selected Range: Atm($atm) - Bp1($bp1) (Diff: $d2)');
    } else if (d3 <= d1 && d3 <= d2 && d3 <= d4) {
      debugPrint('Selected Range: Ap1($ap1) - Btm($btm) (Diff: $d3)');
    } else {
      debugPrint('Selected Range: Ap1($ap1) - Bp1($bp1) (Diff: $d4)');
    }

    // 値の決定（上記の判定を再利用して値をセット）
    int startT, endT;
    if (d1 <= d2 && d1 <= d3 && d1 <= d4) {
      startT = atm;
      endT = btm;
    } else if (d2 <= d1 && d2 <= d3 && d2 <= d4) {
      startT = atm;
      endT = bp1!;
    } else if (d3 <= d1 && d3 <= d2 && d3 <= d4) {
      startT = ap1!;
      endT = btm;
    } else {
      startT = ap1!;
      endT = bp1!;
    }

    // 開始終了が逆転している場合の補正は fetchCellsByTimeRange 内の min/max で行われるが念のため確認
    debugPrint('Searching Time Range: $startT - $endT');

    // 範囲検索
    // startT, endT の間のセルを取得
    // どちらが過去かわからないので fetchCellsByTimeRange 内で min/max 処理される
    final cells = await _databaseRepository.fetchCellsByTimeRange(startT, endT);

    _highlightCells = cells.toSet();
    _updateHighlightCache(); // Highlight cache update
    isDeleteReady = true;
    _refreshTileOverlay(); // ハイライト描画のため
    notifyListeners();
  }

  /// _highlightCells (Zoom 14 state) based, create cache for parents
  void _updateHighlightCache() {
    _highlightCache.clear();
    for (int z = 3; z <= 14; z++) {
      _highlightCache[z] = {};
    }

    const int baseZ = 14;
    for (final cell in _highlightCells) {
      // Zoom 14 -> add itself
      _highlightCache[14]!.add('${cell.lat}_${cell.lng}');

      // Zoom 3..13 -> add parent
      for (int z = 3; z < baseZ; z++) {
        final double divisor = pow(2, baseZ - z).toDouble();
        final int parentLat = (cell.lat / divisor).floor();
        final int parentLng = (cell.lng / divisor).floor();
        _highlightCache[z]!.add('${parentLat}_${parentLng}');
      }
    }
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

      // ハイライト描画 (区間削除モード用)
      if (isDeleteSectionMode) {
        bool shouldHighlight = false;
        // Check cache
        if (_highlightCache.containsKey(cellZ)) {
          final key = '${cell.lat}_${cell.lng}';
          if (_highlightCache[cellZ]!.contains(key)) {
            shouldHighlight = true;
          }
        }

        if (shouldHighlight) {
          final paintHighlight = Paint()
            ..color = Colors.red
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0; // Zoomレベルに応じて太さを調整しても良い
          canvas.drawRect(r, paintHighlight);
        }
      }
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

    final cell = await _databaseRepository.getCell(targetZ, latIndex, lngIndex);

    if (isDeleteSectionMode) {
      if (cell != null) {
        // 2点目(B)の選択処理
        await _handleDeleteSectionSelection(cell);
      }
      return null; // 詳細ダイアログを出さないようにnullを返す
    }

    return cell;
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

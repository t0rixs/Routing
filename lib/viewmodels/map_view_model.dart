import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/cell.dart';
import '../repositories/database_repository.dart';
import '../services/png_encoder_pool.dart';
import '../utils/cell_index.dart';

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
  int get tileRefreshCounter => _tileOverlayCounter;

  // --- 位置に基づくセル記録 ---
  StreamSubscription<Position>? _positionSub;
  LatLng? _lastRecordedLatLng;

  /// 直近の受信 GPS 座標（follow モードでカメラを追従させるため保持）。
  LatLng? _lastKnownPosition;
  LatLng? get lastKnownPosition => _lastKnownPosition;

  /// Follow モード（地図中心を現在地に追従）有効フラグ。
  bool _followUser = false;
  bool get followUser => _followUser;

  /// follow 中にカメラを移動すべきタイミングを通知するためのカウンタ。
  /// Widget 側で値の変化を検知して `animateCamera` を呼ぶ。
  int _followTick = 0;
  int get followTick => _followTick;

  /// follow モードを切り替える。ON 時に現在地が既知ならば即座に追従する。
  void toggleFollowUser() {
    _followUser = !_followUser;
    if (_followUser && _lastKnownPosition != null) {
      _followTick++;
    }
    notifyListeners();
  }

  /// ユーザーが地図を手動操作した場合に follow を解除する（UX 的に自然）。
  void disableFollowUser() {
    if (!_followUser) return;
    _followUser = false;
    notifyListeners();
  }

  /// DB に記録済みだが TileOverlay にはまだ反映していない新規セル数。
  /// 一定数に達するか、ズームレベル変更時にまとめて TileOverlay を再生成する
  /// （明滅抑止 + 既存セルの val/色/サイズを正しく反映させる）。
  int _pendingRecordedCount = 0;
  static const int _pendingFlushThreshold = 5;

  /// 直近に観測した地図ズーム（整数レベル）。ズーム階調が変わったタイミングで
  /// pending をフラッシュしてタイルキャッシュを破棄する。
  int? _lastObservedZoomLevel;

  /// 最後にプリフェッチ要求した `(cellZ, shard range)`。
  /// 同一ビューポートでの重複プリフェッチを抑止する。
  int? _lastPrefetchCellZ;
  int? _lastPrefetchDbLatStart;
  int? _lastPrefetchDbLatEnd;
  int? _lastPrefetchDbLngStart;
  int? _lastPrefetchDbLngEnd;

  // --- Manual Cell Size Mode ---
  bool _isManualCellSize = false;
  int _manualCellZ = 14;
  bool get isManualCellSize => _isManualCellSize;
  int get manualCellZ => _manualCellZ;

  void setManualCellSize(int cellZ) {
    _isManualCellSize = true;
    _manualCellZ = cellZ.clamp(3, 14);
    refreshMap();
    notifyListeners();
  }

  void setAutoCellSize() {
    _isManualCellSize = false;
    refreshMap();
    notifyListeners();
  }

  /// 手動モードで、指定された地図ズームに対する自然な cellZ よりも
  /// 細かいセル（= 手動 cellZ の方が大きい）を描画しているかどうか。
  /// true のときはセル境界の黒線を描かずに視認性を確保する。
  bool shouldHideCellStroke(int mapZoom) {
    if (!_isManualCellSize) return false;
    final int autoCellZ = mapZoom.clamp(3, 14);
    return _manualCellZ > autoCellZ;
  }

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
    unawaited(startLocationRecording());
  }

  /// ストリーム用（タイムアウトなし）。
  /// Android は foreground service を起動してバックグラウンドでも位置を受信する。
  /// iOS は後続対応予定（現状はフォアグラウンドのみ）。
  LocationSettings _streamLocationSettings() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Routing',
            notificationText: '移動履歴を記録中...',
            enableWakeLock: true,
            notificationIcon: AndroidResource(
              name: 'ic_launcher',
              defType: 'mipmap',
            ),
          ),
        );
      case TargetPlatform.iOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: false,
          activityType: ActivityType.other,
        );
      default:
        return const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        );
    }
  }

  /// 位置ストリームを開始し、移動ごとにセルを記録する。
  /// Android / iOS のみで動作し、それ以外のプラットフォームでは no-op。
  Future<void> startLocationRecording() async {
    if (_positionSub != null) return;
    if (!(defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS)) {
      return;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.unableToDetermine) {
      return;
    }

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return;
    }

    final settings = _streamLocationSettings();

    _positionSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      _onPositionUpdate,
      onError: (_, __) {},
      cancelOnError: false,
    );
  }

  void _onPositionUpdate(Position position) {
    final current = LatLng(position.latitude, position.longitude);
    final previous = _lastRecordedLatLng;
    _lastRecordedLatLng = current;
    _lastKnownPosition = current;
    if (previous != null) {
      unawaited(_recordCellsForMovement(previous, current));
    }
    if (_followUser) {
      _followTick++;
      notifyListeners();
    }
  }

  /// 前回位置から現在位置までを結ぶ線分が貫通する Zoom14 セル（DDA 判定）を
  /// 重複なく DB に書き込む。DB 記録は毎回即座に完了させるため、ズーム変更などの
  /// タイミングで TileOverlay を作り直せば常に最新状態が反映される。
  /// 描画自体は pending カウンタがしきい値に達したときのみ
  /// [_refreshTileOverlay] を呼び出す（明滅抑止 / 既存 cell val を正しく反映）。
  Future<void> _recordCellsForMovement(LatLng from, LatLng to) async {
    final cells = CellIndex.cellsOnSegment(from, to);
    if (cells.isEmpty) return;
    await _databaseRepository.recordVisitedCells14(cells);
    _pendingRecordedCount += cells.length;
    if (_pendingRecordedCount >= _pendingFlushThreshold) {
      _flushPendingRecordings();
    }
  }

  /// pending を 0 に戻してタイルを再生成する。
  void _flushPendingRecordings() {
    if (_pendingRecordedCount == 0) return;
    _pendingRecordedCount = 0;
    _refreshTileOverlay();
  }

  /// 位置ストリームを停止する（ウィジェット破棄時など）。
  void disposeLocationRecording() {
    _positionSub?.cancel();
    _positionSub = null;
    _lastRecordedLatLng = null;
  }

  void onCameraMove(CameraPosition position) {
    _cameraPosition = position;
  }

  /// カメラ操作が落ち着いたタイミングのフック。
  /// 拡大率（整数ズームレベル）が変わっていて、未反映の新規 cell が残っていれば
  /// 即座に TileOverlay を再生成してタイルキャッシュを破棄する
  /// （古いズームで描画された古い絵を掴み続けるのを防ぐ）。
  void onCameraIdle() {
    final int currentZoom = _cameraPosition.zoom.floor();
    final int? prev = _lastObservedZoomLevel;
    _lastObservedZoomLevel = currentZoom;
    if (prev != null && prev != currentZoom && _pendingRecordedCount > 0) {
      _flushPendingRecordings();
    }
  }

  /// ビューポートに対応する shard をまとめて DB から取り出し、
  /// `DatabaseRepository._shardCellCache` に載せる。
  /// `map_widget` 側で `GoogleMapController.getVisibleRegion()` の結果を渡す想定。
  ///
  /// `getTile` → `_queryShardCells` はキャッシュヒット時 in-memory filter で済むので、
  /// ズーム変更直後の初回タイル生成 DB 待ちを大幅に削減できる。
  void requestViewportPrefetch(LatLngBounds bounds) {
    final int mapZoom = _cameraPosition.zoom.floor();
    final int cellZ = _isManualCellSize ? _manualCellZ : mapZoom.clamp(3, 14);
    final double cellSize = (0.0002 * pow(2, 14 - cellZ)).toDouble();

    double eastLon = bounds.northeast.longitude;
    if (eastLon <= -180.0 + 1e-12) eastLon = 180.0;
    final double eastForIndex = eastLon - 1e-9;
    final double northForIndex = bounds.northeast.latitude - 1e-9;

    final int sLat = ((bounds.southwest.latitude + 90) / cellSize).floor();
    final int nLat = ((northForIndex + 90) / cellSize).floor();
    final int wLng = ((bounds.southwest.longitude + 180) / cellSize).floor();
    final int eLng = ((eastForIndex + 180) / cellSize).floor();

    final int dbLatStart = sLat ~/ 1000;
    final int dbLatEnd = nLat ~/ 1000;
    final int dbLngStart = wLng ~/ 1000;
    final int dbLngEnd = eLng ~/ 1000;

    if (_lastPrefetchCellZ == cellZ &&
        _lastPrefetchDbLatStart == dbLatStart &&
        _lastPrefetchDbLatEnd == dbLatEnd &&
        _lastPrefetchDbLngStart == dbLngStart &&
        _lastPrefetchDbLngEnd == dbLngEnd) {
      return;
    }
    _lastPrefetchCellZ = cellZ;
    _lastPrefetchDbLatStart = dbLatStart;
    _lastPrefetchDbLatEnd = dbLatEnd;
    _lastPrefetchDbLngStart = dbLngStart;
    _lastPrefetchDbLngEnd = dbLngEnd;

    unawaited(_databaseRepository.prefetchShards(
      cellZ: cellZ,
      sLat: sLat,
      nLat: nLat,
      wLng: wLng,
      eLng: eLng,
    ));
  }

  /// タイルオーバーレイを更新 (再描画)。
  /// 新しい TileOverlayId に切り替わることで既存タイルキャッシュが破棄される。
  void _refreshTileOverlay() {
    if (_tileOverlayCounter > 1000) _tileOverlayCounter = 0;
    _tileOverlayCounter++;

    // 明示的なフル再描画タイミングでは pending もクリアして整合を取る。
    _pendingRecordedCount = 0;

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
    // 画質維持のため 512 固定。PNG エンコードは後段の isolate pool で
    // level 0 並列化することで短縮する。
    const int ts = 512;

    if (zoomDesc == null) {
      // 描画不要: null data で空タイル扱い（PNG 生成スキップ）。
      return const Tile(512, 512, null);
    }

    // Zoomレベルの決定: 3..14 にクランプ（手動モード時は固定値）
    final int tileZ = zoomDesc;
    final int cellZ = _isManualCellSize ? _manualCellZ : tileZ.clamp(3, 14);

    // データを取得
    final cells =
        await _databaseRepository.fetchCells(tileZ, cellZ, tileX, tileY);

    if (cells.isEmpty) {
      // セル 0 件 → PNG 生成せず null data で透明タイルを返す。
      // これだけで、データ未到達エリアの描画コストがほぼ 0 になる。
      return const Tile(512, 512, null);
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Paint をループ外で 1 度だけ確保して使い回す（GC 圧力削減）。
    final Paint paintFill = Paint()..style = PaintingStyle.fill;
    final Paint paintStroke = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    final Paint paintHighlight = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // 手動モードで cellZ が自動より細かい場合、境界線が密集して見づらいので
    // ストロークを描かない。また、セル密集時（500+）は drawRect × stroke が
    // PictureRecorder コスト支配要因になるため自動的にスキップする。
    final bool hideStroke = shouldHideCellStroke(tileZ) || cells.length > 500;

    final double tsD = ts.toDouble();
    final double tileOriginX = tileX * tsD;
    final double tileOriginY = tileY * tsD;

    Rect cellRectInThisTile(int latIndex, int lngIndex) {
      final LatLngBounds b = _cellToLatLngBounds(cellZ, latIndex, lngIndex);
      final Point<double> sw = latLngToWorldPixel(
          b.southwest.latitude, b.southwest.longitude, tileZ, ts);
      final Point<double> ne = latLngToWorldPixel(
          b.northeast.latitude, b.northeast.longitude, tileZ, ts);

      final double pxW = sw.x - tileOriginX;
      final double pyS = sw.y - tileOriginY;
      final double pxE = ne.x - tileOriginX;
      final double pyN = ne.y - tileOriginY;

      final double left = min(pxW, pxE);
      final double top = min(pyN, pyS);
      final double width = (pxE - pxW).abs();
      final double height = (pyS - pyN).abs();
      return Rect.fromLTWH(left, top, width, height);
    }

    final Set<String>? highlightSetForZ =
        isDeleteSectionMode ? _highlightCache[cellZ] : null;

    for (final cell in cells) {
      final Rect r = cellRectInThisTile(cell.lat, cell.lng);
      if (r.right <= 0 || r.bottom <= 0 || r.left >= ts || r.top >= ts) {
        continue;
      }

      paintFill.color = _calculateCellColor(cell.val, cellZ);
      canvas.drawRect(r, paintFill);

      if (!hideStroke) {
        canvas.drawRect(r, paintStroke);
      }

      if (highlightSetForZ != null &&
          highlightSetForZ.contains('${cell.lat}_${cell.lng}')) {
        canvas.drawRect(r, paintHighlight);
      }
    }

    // 以下で PNG を生成する。Flutter 標準の `ui.ImageByteFormat.png` は
    // メイン isolate で zlib 圧縮まで行うためズーム変更時のボトルネックになる。
    // そこで rawStraightRgba で raw ピクセルだけ取り出し、圧縮レベル 0 の PNG
    // エンコードを別 isolate pool で並列実行する。
    final picture = recorder.endRecording();
    final image = await picture.toImage(ts, ts);
    try {
      final rgbaByteData =
          await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (rgbaByteData == null) return const Tile(512, 512, null);
      final rgba = rgbaByteData.buffer.asUint8List();
      final pngBytes =
          await PngEncoderPool.instance.encode(rgba, ts, ts);
      return Tile(ts, ts, pngBytes);
    } finally {
      image.dispose();
    }
  }

  /// `flutter_map` 向け: タイル画像を直接 `ui.Image` として返す。
  /// PNG エンコード/デコードのオーバーヘッドを回避する。
  Future<ui.Image> getTileImage(int tileX, int tileY, int zoomDesc) async {
    const int ts = 512;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final int tileZ = zoomDesc;
    final int cellZ = _isManualCellSize ? _manualCellZ : tileZ.clamp(3, 14);

    final cells =
        await _databaseRepository.fetchCells(tileZ, cellZ, tileX, tileY);

    if (cells.isNotEmpty) {
      final Paint paintFill = Paint()..style = PaintingStyle.fill;
      final Paint paintStroke = Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5;
      final Paint paintHighlight = Paint()
        ..color = Colors.red
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      final double tsD = ts.toDouble();
      final double tileOriginX = tileX * tsD;
      final double tileOriginY = tileY * tsD;

      Rect cellRectInThisTile(int latIndex, int lngIndex) {
        final LatLngBounds b = _cellToLatLngBounds(cellZ, latIndex, lngIndex);
        final Point<double> sw = latLngToWorldPixel(
            b.southwest.latitude, b.southwest.longitude, tileZ, ts);
        final Point<double> ne = latLngToWorldPixel(
            b.northeast.latitude, b.northeast.longitude, tileZ, ts);

        final double pxW = sw.x - tileOriginX;
        final double pyS = sw.y - tileOriginY;
        final double pxE = ne.x - tileOriginX;
        final double pyN = ne.y - tileOriginY;

        final double left = min(pxW, pxE);
        final double top = min(pyN, pyS);
        final double width = (pxE - pxW).abs();
        final double height = (pyS - pyN).abs();
        return Rect.fromLTWH(left, top, width, height);
      }

      final Set<String>? highlightSetForZ =
          isDeleteSectionMode ? _highlightCache[cellZ] : null;

      for (final cell in cells) {
        final Rect r = cellRectInThisTile(cell.lat, cell.lng);
        if (r.right <= 0 || r.bottom <= 0 || r.left >= ts || r.top >= ts) {
          continue;
        }

        paintFill.color = _calculateCellColor(cell.val, cellZ);
        canvas.drawRect(r, paintFill);
        canvas.drawRect(r, paintStroke);

        if (highlightSetForZ != null &&
            highlightSetForZ.contains('${cell.lat}_${cell.lng}')) {
          canvas.drawRect(r, paintHighlight);
        }
      }
    }

    final picture = recorder.endRecording();
    return picture.toImage(ts, ts);
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
        .withValues(alpha: 1); // 透過度調整
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

  /// 表示範囲内のセルを Polygon 描画用データとして返す（flutter_map 用）
  ///
  /// タイル座標は表示中の地図ズーム（[zoom]）を使い、
  /// cellZ（セルの細かさ）は手動モード時は [_manualCellZ]、そうでなければ
  /// 自動で地図ズームに合わせる。手動モードでは auto-zoom-down は行わない。
  Future<List<CellPolygon>> fetchCellPolygons(
      double south, double north, double west, double east, int zoom) async {
    final int cellZ = _isManualCellSize ? _manualCellZ : zoom.clamp(3, 14);

    // タイル座標は地図ズームを基準にする（getTile と同じ考え方）
    final int tileZ = zoom.clamp(3, 19);

    final double tileCount = pow(2.0, tileZ).toDouble();
    final double worldTileWidth = 360.0 / tileCount;

    int tileXStart = ((west + 180) / worldTileWidth).floor();
    int tileXEnd = ((east + 180) / worldTileWidth).floor();
    final double latRadS = south * pi / 180.0;
    final double latRadN = north * pi / 180.0;
    final double yTileS =
        (1 - log(tan(pi / 4 + latRadS / 2)) / pi) / 2 * tileCount;
    final double yTileN =
        (1 - log(tan(pi / 4 + latRadN / 2)) / pi) / 2 * tileCount;
    int tileYStart = yTileN.floor();
    int tileYEnd = yTileS.floor();

    // タイル数が多すぎる場合は tileZ を下げて範囲を圧縮する（自動モードのみ）。
    // 手動モードではユーザの意図を尊重し、上限だけ設ける。
    const int maxTileSide = 8;
    int tilesWide = tileXEnd - tileXStart + 1;
    int tilesHigh = tileYEnd - tileYStart + 1;
    if (tilesWide > maxTileSide) {
      tileXEnd = tileXStart + maxTileSide - 1;
    }
    if (tilesHigh > maxTileSide) {
      tileYEnd = tileYStart + maxTileSide - 1;
    }

    // タイル並列フェッチ
    final futures = <Future<Set<Cell>>>[];
    for (int tx = tileXStart; tx <= tileXEnd; tx++) {
      for (int ty = tileYStart; ty <= tileYEnd; ty++) {
        futures.add(_databaseRepository.fetchCells(tileZ, cellZ, tx, ty));
      }
    }
    final chunks = await Future.wait(futures);
    final Set<Cell> allCells = {};
    for (final c in chunks) {
      allCells.addAll(c);
    }

    if (allCells.isEmpty) return [];

    // CellPolygon に変換
    final double cs = (0.0002 * pow(2, 14 - cellZ)).toDouble();
    final List<CellPolygon> result = [];
    for (final cell in allCells) {
      final double cellSouth = cell.lat * cs - 90.0;
      final double cellNorth = cellSouth + cs;
      final double cellWest = cell.lng * cs - 180.0;
      final double cellEast = cellWest + cs;
      if (cellNorth < south ||
          cellSouth > north ||
          cellEast < west ||
          cellWest > east) {
        continue;
      }

      final color = _calculateCellColor(cell.val, cellZ);
      final isHighlighted = isDeleteSectionMode &&
          _highlightCache.containsKey(cellZ) &&
          _highlightCache[cellZ]!.contains('${cell.lat}_${cell.lng}');

      result.add(CellPolygon(
        south: cellSouth,
        north: cellNorth,
        west: cellWest,
        east: cellEast,
        color: color,
        isHighlighted: isHighlighted,
      ));
    }
    return result;
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

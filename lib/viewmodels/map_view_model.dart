import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/cell.dart';
import '../repositories/database_repository.dart';
import '../services/background_activity_service.dart';
import '../utils/cell_index.dart';

/// マップの表示状態とデータロードを管理するViewModel
class MapViewModel extends ChangeNotifier with WidgetsBindingObserver {
  MapViewModel() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    disposeLocationRecording();
    super.dispose();
  }

  /// アプリがバックグラウンド（paused/inactive/hidden/detached）にあるか。
  /// 位置記録は継続するが、UI 再計算・タイル再生成・stats 集計は抑止する。
  bool _appInBackground = false;
  bool get appInBackground => _appInBackground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final bool wasInBackground = _appInBackground;
    _appInBackground = state != AppLifecycleState.resumed;
    if (wasInBackground && !_appInBackground) {
      // フォアグラウンド復帰時: BG 中に蓄積された記録を 1 回だけ反映する。
      // - HUD の数値を最新化
      // - タイルを作り直して BG で記録された cell を可視化
      refreshTotalStats(immediate: true);
      _refreshTileOverlay();
    }
  }

  final DatabaseRepository _databaseRepository = DatabaseRepository();

  // SharedPreferences のキー（カメラ位置の保存／復元に使用）
  static const String _kPrefCameraLat = 'map_camera_lat';
  static const String _kPrefCameraLng = 'map_camera_lng';
  static const String _kPrefCameraZoom = 'map_camera_zoom';
  static const String _kPrefCameraBearing = 'map_camera_bearing';
  static const String _kPrefCameraTilt = 'map_camera_tilt';

  /// 起動時のフォールバック座標（東京駅）。
  /// 保存値も現在地も取得できない場合のみ使用される。
  static const LatLng _fallbackCenter = LatLng(35.6895, 139.6917);

  // 現在のカメラ位置
  CameraPosition _cameraPosition =
      const CameraPosition(target: _fallbackCenter, zoom: 14);
  CameraPosition get cameraPosition => _cameraPosition;

  /// 起動時のカメラ位置初期化が完了したかどうか。
  /// `false` の間は保存処理を抑止し、初期化中の上書きを防ぐ。
  bool _cameraInitialized = false;
  bool get cameraInitialized => _cameraInitialized;

  // TileOverlay
  TileOverlay? _tileOverlay;
  TileOverlay? get tileOverlay => _tileOverlay;

  // タイル更新用カウンタ to force refresh
  int _tileOverlayCounter = 0;
  int get tileRefreshCounter => _tileOverlayCounter;

  // --- 位置に基づくセル記録 ---
  StreamSubscription<Position>? _positionSub;
  LatLng? _lastRecordedLatLng;

  /// インポート等、DB を一時的に触れない期間のフラグ。true の間:
  /// - GPS 位置ストリームを完全にキャンセルし、書き込みを一切行わない
  /// - TileOverlay 再生成や描画要求を全て no-op 化する
  /// - getTile / getTileImage / fetchCellPolygons は即座に空タイルを返す
  /// これにより、`closeAll()` 後にファイルが移動／削除されている最中でも
  /// SQLITE_READONLY_DBMOVED などのエラーがメインスレッドに流入せず、
  /// 「Processing Data」オーバーレイが即座にレンダリングされる。
  bool _isBusy = false;
  bool get isBusy => _isBusy;

  /// タイル解像度（1 辺の px 数）。320/480/512 の 3 段階をユーザが切り替える。
  /// 変更すると TileOverlay を作り直して再レンダリングを走らせる。
  int _tileResolution = 480;
  int get tileResolution => _tileResolution;

  /// 許可される解像度値。UI の選択肢と一致させる。
  static const List<int> tileResolutionOptions = <int>[320, 480, 512];

  void setTileResolution(int ts) {
    if (!tileResolutionOptions.contains(ts)) return;
    if (_tileResolution == ts) return;
    _tileResolution = ts;
    unawaited(_persistTileResolution());
    _refreshTileOverlay();
    notifyListeners();
  }

  static const String _kPrefTileResolution = 'tile_resolution';

  Future<void> _persistTileResolution() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefTileResolution, _tileResolution);
    } catch (_) {}
  }

  Future<void> _loadTileResolution() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_kPrefTileResolution);
      if (v != null && tileResolutionOptions.contains(v)) {
        _tileResolution = v;
      }
    } catch (_) {}
  }

  // --- Google Maps ベースマップのスタイル ---
  /// ベースのテーマ（Light / Dark）。メニューから切り替える。
  /// 細かい表示項目のトグルは `_styleOverrides` で管理する（設定画面から変更）。
  MapBaseStyle _mapBaseStyle = MapBaseStyle.standard;
  MapBaseStyle get mapBaseStyle => _mapBaseStyle;

  /// 現在の UI テーマがダークかどうか。`cycleMapBaseStyle` で「通常」へ戻すときに
  /// `standard` ではなく `dark` を選ぶための判断材料。
  /// `_loadMapBaseStyle` で SharedPreferences から復元され、メニューでテーマが
  /// 切り替わると [syncThemeIsDark] 経由で更新される。
  bool _themeIsDark = false;

  /// 外部（メニュー UI）から UI テーマの変更を通知する。
  /// マップのベーススタイル自体はここでは触らず、`cycleMapBaseStyle` の挙動に
  /// 影響するだけ（メニューは別途 `setMapBaseStyle` を呼んでいる）。
  void syncThemeIsDark(bool isDark) {
    if (_themeIsDark == isDark) return;
    _themeIsDark = isDark;
  }

  /// ベーススタイルに重ねる個別トグル設定。
  MapStyleOverrides _styleOverrides = const MapStyleOverrides();
  MapStyleOverrides get styleOverrides => _styleOverrides;

  int _mapStyleTick = 0;
  int get mapStyleTick => _mapStyleTick;

  /// 画面 HUD 用: z=14 における重複なし／重複ありセル数の統計。
  /// `recordVisitedCells14` 完了後や画面初期化時に `refreshTotalStats` で更新する。
  int _totalUniqueCells = 0;
  int _totalVisits = 0;
  int get totalUniqueCells => _totalUniqueCells;
  int get totalVisits => _totalVisits;

  /// 日付フィルタ: 有効時、初回訪問(p1) または 最終訪問(tm) がこの期間に
  /// 含まれるセルだけを赤系グラデーションで、それ以外を灰色で描画する。
  /// 両日付は日単位（時刻は 00:00:00 〜 23:59:59 を内部で補間）。
  bool _dateFilterEnabled = false;
  DateTime? _dateFilterStart;
  DateTime? _dateFilterEnd;
  bool get dateFilterEnabled => _dateFilterEnabled;
  DateTime? get dateFilterStart => _dateFilterStart;
  DateTime? get dateFilterEnd => _dateFilterEnd;

  /// 日付フィルタを設定。`enabled=false` なら無効化し通常描画に戻す。
  /// 変更時はタイルキャッシュを破棄して再描画を促す。
  void setDateFilter({
    required bool enabled,
    DateTime? start,
    DateTime? end,
  }) {
    _dateFilterEnabled = enabled;
    if (start != null) _dateFilterStart = DateTime(start.year, start.month, start.day);
    if (end != null) _dateFilterEnd = DateTime(end.year, end.month, end.day);
    // start/end が共に null ならデフォルト（今日）に。
    if (_dateFilterStart == null || _dateFilterEnd == null) {
      final today = DateTime.now();
      _dateFilterStart ??= DateTime(today.year, today.month, today.day);
      _dateFilterEnd ??= DateTime(today.year, today.month, today.day);
    }
    // 範囲が逆転していたら入れ替え。
    if (_dateFilterStart!.isAfter(_dateFilterEnd!)) {
      final tmp = _dateFilterStart!;
      _dateFilterStart = _dateFilterEnd;
      _dateFilterEnd = tmp;
    }
    _clearTilePngCache();
    // TileOverlay を強制再生成（throttle/isBusy を回避）。
    _lastRefreshTime = null;
    if (_tileOverlayCounter > 1000) _tileOverlayCounter = 0;
    _tileOverlayCounter++;
    _tileOverlay = TileOverlay(
      tileOverlayId: TileOverlayId('heatmap_overlay_$_tileOverlayCounter'),
      tileProvider: _HeatmapTileProvider(this),
      transparency: 0.0,
      fadeIn: false,
    );
    notifyListeners();
  }

  /// Stats 再計算のデバウンス用タイマー。
  Timer? _statsRefreshTimer;
  bool _statsRefreshInFlight = false;

  /// z=14 の総セル数（重複なし）と延べ訪問数（重複あり = val 総和）を再計算し、
  /// 変化があれば notifyListeners する。
  ///
  /// 連続呼び出しを吸収するため、内部で 500ms デバウンスする。
  void refreshTotalStats({bool immediate = false}) {
    _statsRefreshTimer?.cancel();
    if (immediate) {
      _doRefreshTotalStats();
      return;
    }
    _statsRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      _doRefreshTotalStats();
    });
  }

  Future<void> _doRefreshTotalStats() async {
    if (_statsRefreshInFlight) return;
    _statsRefreshInFlight = true;
    try {
      final s = await _databaseRepository.getZ14TotalStats();
      if (s.uniqueCells != _totalUniqueCells ||
          s.totalVisits != _totalVisits) {
        _totalUniqueCells = s.uniqueCells;
        _totalVisits = s.totalVisits;
        notifyListeners();
        // タスクキル後の再起動でも 0/0 にならないよう永続化する。
        unawaited(_saveTotalStatsToPrefs());
      }
    } catch (_) {
      // 統計は HUD 用の装飾要素。取得失敗は黙って無視。
    } finally {
      _statsRefreshInFlight = false;
    }
  }

  Future<void> _saveTotalStatsToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefTotalUniqueCells, _totalUniqueCells);
      await prefs.setInt(_kPrefTotalVisits, _totalVisits);
    } catch (_) {
      // 永続化失敗は致命ではない。
    }
  }

  Future<void> _loadTotalStatsFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final u = prefs.getInt(_kPrefTotalUniqueCells);
      final v = prefs.getInt(_kPrefTotalVisits);
      if (u != null && v != null && (u != 0 || v != 0)) {
        _totalUniqueCells = u;
        _totalVisits = v;
        notifyListeners();
      }
    } catch (_) {
      // 失敗時は 0/0 のまま。直後の DB 再計算で更新される。
    }
  }

  /// GoogleMapController.setMapStyle に渡す JSON。未適用（完全デフォルト）時は null。
  ///
  /// 合成規則:
  ///   1. base が dark なら `_kDarkRules` を全て追加
  ///   2. 個別トグルで off になっている項目に対して `visibility: off` の
  ///      スタイルを末尾に追加（Google Maps は後勝ちで適用される）
  ///   3. 追加 rule が 1 件もなく base が standard なら null を返す（= 完全デフォルト）
  String? get mapStyleJson {
    final List<Map<String, dynamic>> rules = <Map<String, dynamic>>[];
    if (_mapBaseStyle == MapBaseStyle.dark) {
      rules.addAll(_kDarkRules);
    }
    final o = _styleOverrides;
    void hide(String featureType, {String? elementType}) {
      rules.add(<String, dynamic>{
        'featureType': featureType,
        if (elementType != null) 'elementType': elementType,
        'stylers': <Map<String, dynamic>>[
          <String, dynamic>{'visibility': 'off'},
        ],
      });
    }

    if (!o.showPoiBusiness) hide('poi.business');
    if (!o.showPoiPark) hide('poi.park');
    if (!o.showPoiAttraction) hide('poi.attraction');
    if (!o.showPoiGovernment) hide('poi.government');
    if (!o.showPoiMedical) hide('poi.medical');
    if (!o.showPoiSchool) hide('poi.school');
    if (!o.showPoiPlaceOfWorship) hide('poi.place_of_worship');
    if (!o.showPoiSportsComplex) hide('poi.sports_complex');
    if (!o.showTransitLine) hide('transit.line');
    if (!o.showRailwayStation) hide('transit.station.rail');
    if (!o.showBusStation) hide('transit.station.bus');
    if (!o.showAirport) hide('transit.station.airport');
    if (!o.showRoadLabels) hide('road', elementType: 'labels');
    if (!o.showAdminLabels) hide('administrative', elementType: 'labels');

    if (_mapBaseStyle == MapBaseStyle.standard && rules.isEmpty) {
      return null;
    }
    return jsonEncode(rules);
  }

  static const String _kPrefMapBaseStyle = 'map_base_style';
  static const String _kPrefOverridesJson = 'map_style_overrides_json';
  static const String _kPrefTotalUniqueCells = 'hud_total_unique_cells';
  static const String _kPrefTotalVisits = 'hud_total_visits';

  void setMapBaseStyle(MapBaseStyle style) {
    if (_mapBaseStyle == style) return;
    _mapBaseStyle = style;
    _mapStyleTick++;
    unawaited(_persistMapBaseStyle());
    notifyListeners();
  }

  /// 画面右下のマップスタイル切替ボタン用: 衛星 → 白紙 → 通常 を循環。
  /// 細かい dark テーマや POI トグルは設定画面側で扱う。
  ///
  /// 「通常」位置は現在の UI テーマに連動する。ダークテーマ ON 中は dark を、
  /// それ以外は standard を選ぶ。これによりダークテーマ中に循環しても地図が
  /// ライトに戻らない。
  void cycleMapBaseStyle() {
    final MapBaseStyle next;
    switch (_mapBaseStyle) {
      case MapBaseStyle.satellite:
        next = MapBaseStyle.blank;
        break;
      case MapBaseStyle.blank:
        next = _themeIsDark ? MapBaseStyle.dark : MapBaseStyle.standard;
        break;
      case MapBaseStyle.standard:
      case MapBaseStyle.dark:
        next = MapBaseStyle.satellite;
        break;
    }
    setMapBaseStyle(next);
  }

  /// `GoogleMap.mapType` に渡す値。`blank` は `MapType.none` を使う。
  MapType get googleMapType {
    switch (_mapBaseStyle) {
      case MapBaseStyle.satellite:
        return MapType.satellite;
      case MapBaseStyle.blank:
        return MapType.none;
      case MapBaseStyle.standard:
      case MapBaseStyle.dark:
        return MapType.normal;
    }
  }

  /// 設定画面から個別トグルを更新する。
  void setStyleOverrides(MapStyleOverrides overrides) {
    if (_styleOverrides == overrides) return;
    _styleOverrides = overrides;
    _mapStyleTick++;
    unawaited(_persistStyleOverrides());
    notifyListeners();
  }

  Future<void> _persistMapBaseStyle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefMapBaseStyle, _mapBaseStyle.index);
    } catch (_) {}
  }

  Future<void> _persistStyleOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kPrefOverridesJson, jsonEncode(_styleOverrides.toJson()));
    } catch (_) {}
  }

  Future<void> _loadMapBaseStyle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt(_kPrefMapBaseStyle);
      if (idx != null && idx >= 0 && idx < MapBaseStyle.values.length) {
        _mapBaseStyle = MapBaseStyle.values[idx];
      }
      // ThemeController の保存値（'app_theme_mode'）と地図ベーススタイルを同期する。
      // 例: ユーザがメニューでダークを ON → その後右下 FAB で地図を循環 (satellite→blank→standard)
      // させると、テーマは dark のままだが地図は standard で保存され、再起動時に不整合となる。
      // ここで「テーマ=dark なのに地図=standard」「テーマ=light なのに地図=dark」のズレを補正する。
      final themeStr = prefs.getString('app_theme_mode');
      _themeIsDark = themeStr == 'dark';
      if (_themeIsDark && _mapBaseStyle == MapBaseStyle.standard) {
        _mapBaseStyle = MapBaseStyle.dark;
      } else if (!_themeIsDark && _mapBaseStyle == MapBaseStyle.dark) {
        _mapBaseStyle = MapBaseStyle.standard;
      }
      final ojson = prefs.getString(_kPrefOverridesJson);
      if (ojson != null && ojson.isNotEmpty) {
        try {
          _styleOverrides =
              MapStyleOverrides.fromJson(jsonDecode(ojson) as Map);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 直近の受信 GPS 座標（follow モードでカメラを追従させるため保持）。
  LatLng? _lastKnownPosition;
  LatLng? get lastKnownPosition => _lastKnownPosition;

  /// 位置情報許可が「常に許可」未満（whileInUse / denied / deniedForever）の
  /// 状態で、バックグラウンド記録が機能しないことをユーザに知らせる必要が
  /// あるかを示すフラグ。UI 側は Consumer で購読し、true のとき誘導ダイアログ
  /// を表示する。`clearLocationAlwaysRequired` でクリアされる。
  bool _locationAlwaysRequired = false;
  bool get locationAlwaysRequired => _locationAlwaysRequired;

  /// ユーザが誘導ダイアログを閉じた後に呼ぶ（再表示を抑制する）。
  void clearLocationAlwaysRequired() {
    if (!_locationAlwaysRequired) return;
    _locationAlwaysRequired = false;
    notifyListeners();
  }

  /// Follow モード（地図中心を現在地に追従）有効フラグ。
  bool _followUser = false;
  bool get followUser => _followUser;

  /// 現在地（青アイコン）を GoogleMap に表示するかどうか。
  /// 起動時はデフォルト `true`（= 青アイコン表示）。
  /// follow ボタンを ON にしたタイミングでも `true` を再設定し、
  /// 一度 `true` になった後は OFF に戻しても `true` のまま維持する。
  /// （GoogleMap 側の描画不具合で初期表示されないケースに対し、
  ///  ユーザーが follow ボタンで明示的に再表示できるよう再代入している）
  bool _myLocationVisible = true;
  bool get myLocationVisible => _myLocationVisible;

  /// follow 中にカメラを移動すべきタイミングを通知するためのカウンタ。
  /// Widget 側で値の変化を検知して `animateCamera` を呼ぶ。
  int _followTick = 0;
  int get followTick => _followTick;

  /// follow モードを切り替える。ON 時に現在地が既知ならば即座に追従する。
  void toggleFollowUser() {
    _followUser = !_followUser;
    if (_followUser) {
      // 青アイコンが何らかの理由で表示されていない場合に備えて、
      // `myLocationEnabled` を false→true に瞬間的にトグルして
      // GoogleMap プラグインに再適用を強制する。
      _myLocationVisible = false;
      notifyListeners();
      Future.microtask(() {
        _myLocationVisible = true;
        notifyListeners();
      });
      if (_lastKnownPosition != null) {
        _followTick++;
      }
    }
    notifyListeners();
  }

  /// ユーザーが地図を手動操作した場合に follow を解除する（UX 的に自然）。
  void disableFollowUser() {
    if (!_followUser) return;
    _followUser = false;
    notifyListeners();
  }

  /// インポートなど重処理の前後で呼ぶ。`true` の間は GPS 記録と描画を全停止する。
  /// 完了時に `false` を渡すと GPS の再購読と TileOverlay の再生成が行われる。
  Future<void> setBusy(bool busy) async {
    if (_isBusy == busy) return;
    _isBusy = busy;
    if (busy) {
      // DB への新規書き込みを即座に止める。`_positionSub.cancel()` を await する
      // 前に立てておくことで、cancel 中／cancel 直後に届いてしまった
      // 既発火の `_recordCellsForMovement` future が DB を触るのも防げる。
      _databaseRepository.pauseWrites();
      // 先に GPS を切ることで、close 済みの DB に対する書き込みが発生しなくなる。
      await _positionSub?.cancel();
      _positionSub = null;
      _lastRecordedLatLng = null;
      _pendingRecordedCount = 0;
      // 既存の TileOverlay も無効化して、走り中のタイル生成リクエストを破棄する。
      _tileOverlay = null;
      notifyListeners();
    } else {
      // ImportExportViewModel.importFile の末尾で scanExistingDatabases() が
      // resumeWrites() を呼ぶが、それを呼ばないユースケース（clearAllData 等）
      // でも resume されるよう保険として明示的にも resume しておく。
      _databaseRepository.resumeWrites();
      // 描画を作り直してから位置記録を再開する。
      _refreshTileOverlay();
      notifyListeners();
      unawaited(startLocationRecording());
    }
  }

  /// DB に記録済みだが TileOverlay にはまだ反映していない新規セル数。
  /// 一定数に達するか、ズームレベル変更時にまとめて TileOverlay を再生成する
  /// （明滅抑止 + 既存セルの val/色/サイズを正しく反映させる）。
  int _pendingRecordedCount = 0;
  static const int _pendingFlushThreshold = 5;

  /// `_refreshTileOverlay` の時間ベーススロットル。
  /// GPS 記録中に毎セル flush されると全可視タイルの getTile が連続発火し、
  /// Skia エンコードが重なるため、最短 250ms 間隔で間引く。
  /// 記録から反映までの最大ラグ = 250ms（体感ほぼ無し）。
  static const Duration _refreshThrottle = Duration(milliseconds: 250);
  DateTime? _lastRefreshTime;

  /// ユーザが地図をドラッグ/ピンチ中かどうか。`onCameraMoveStarted` で true,
  /// `onCameraIdle` で false に戻す。true の間は `_refreshTileOverlay` を
  /// 「延期扱い」にして、Google Maps にタイルキャッシュ破棄を発火させない。
  /// ——これが旧アプリ比でジェスチャがカクつく主因だった。
  /// 新 TileOverlayId が届くと GM ネイティブ層が全タイル再取得に入るため、
  /// その間ネイティブコンポジタが忙しくなり指追従が遅れていた。
  bool _isGesturing = false;
  bool _deferredRefresh = false;

  /// 可視ビューポート。`onCameraIdle` のタイミングで Map Widget 側から
  /// 注入される。GPS が画面外の cell を記録しても描画を更新しないように
  /// するための判定に使う。
  LatLngBounds? _currentVisibleBounds;

  /// 出力済みタイル PNG の LRU キャッシュ。
  /// Key: `"ts-tileZ-cellZ-tileX-tileY-hideStroke-delete"` 形式。
  /// Value: (cell 配列の content hash, PNG バイト列)。
  /// GM が overlay refresh 後に `getTile` を呼んだ時、
  /// セル内容が変わっていない (= 前回と hash が一致) なら
  /// 再ラスタライズせず即座にキャッシュ PNG を返す。
  /// shard の content が変わると fetchCells の結果が変わり、
  /// 自動的に hash ミスして再生成されるので無効化の手間はない。
  final LinkedHashMap<String, _TilePngEntry> _tilePngCache =
      LinkedHashMap<String, _TilePngEntry>();
  static const int _tilePngCacheCap = 256;

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
  // Cache for multi-zoom highlighting: Key=ZoomLevel, Value=Set of (lat, lng) records.
  // Record 型を使うことでタイル描画時に文字列連結 (`'${lat}_${lng}'`) のアロケーションを避ける。
  Map<int, Set<(int, int)>> _highlightCache = {};

  void onMapCreated(GoogleMapController controller) {
    _refreshTileOverlay();
    unawaited(startLocationRecording());
  }

  /// ストリーム用（タイムアウトなし）。
  /// Android は foreground service を起動してバックグラウンドでも位置を受信する。
  /// iOS は後続対応予定（現状はフォアグラウンドのみ）。
  ///
  /// バッテリー消費はここではなく `_recordCellsForMovement` 以降の
  /// UI/タイル再生成パスが主因だったため、本設定はユーザー要件どおり
  /// 1 秒間隔・距離フィルタなしの高頻度サンプリングに戻している。
  /// バックグラウンド時は `_appInBackground` ガードで UI 系の処理を全て
  /// 抑止しているので、高頻度サンプリングしても CPU 消費は小さい。
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
            // 通知チャンネル名を明示。Android 8+ ではチャンネル未指定だと
            // OS がデフォルト扱いで通知を弾く場合があるため必須レベル。
            notificationChannelName: 'Routing 位置情報サービス',
            // ユーザが誤って通知をスワイプで消せないようにする
            // (foreground service の通知はスワイプ削除禁止が推奨)。
            setOngoing: true,
            notificationIcon: AndroidResource(
              name: 'ic_notification',
              defType: 'drawable',
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
    if (_isBusy) return;
    if (!_recordingEnabled) return;
    if (!(defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS)) {
      return;
    }

    // Android 13+ は通知を出すのに POST_NOTIFICATIONS ランタイム許可が必須。
    // これがないと foreground service は起動しても通知バーに表示されず、
    // ユーザから見ると「アプリを閉じたら全て止まった」ように見える。
    // 位置情報許可より先に済ませておく。
    if (defaultTargetPlatform == TargetPlatform.android) {
      final notifStatus = await ph.Permission.notification.status;
      if (!notifStatus.isGranted) {
        await ph.Permission.notification.request();
      }
    }

    // 初回起動時のみ、OS の許可ダイアログの前に「なぜバックグラウンドで
    // 位置情報を使うか」を説明する画面を UI に表示させる。UI 側が
    // `acknowledgeLocationRationale()` を呼ぶまで待つ。
    // 既に説明済みの場合はスキップして即座に OS 許可フローへ進む。
    var permissionNow = await Geolocator.checkPermission();
    if (permissionNow == LocationPermission.denied) {
      bool rationaleShown = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        rationaleShown =
            prefs.getBool(_kPrefLocationRationaleShown) ?? false;
      } catch (_) {}
      if (!rationaleShown) {
        _needsLocationRationale = true;
        _rationaleAck = Completer<void>();
        notifyListeners();
        await _rationaleAck!.future;
      }
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
      _locationAlwaysRequired = true;
      notifyListeners();
      return;
    }

    // 権限が付与されたタイミングで GoogleMap の `myLocationEnabled` を
    // 強制的に false→true にトグルし直し、青い現在地アイコンを再表示させる。
    // 初回インストール直後など、Map 初期化時点で権限が無かった場合は
    // 同じ true 値のままだとプラグインが再適用してくれないため。
    _myLocationVisible = false;
    notifyListeners();
    Future.microtask(() {
      _myLocationVisible = true;
      notifyListeners();
    });

    // バックグラウンドで継続記録するには「常に許可」が必要。
    // whileInUse しか取れていない場合は UI から設定画面に誘導する。
    if (permission == LocationPermission.whileInUse) {
      _locationAlwaysRequired = true;
      notifyListeners();
    } else {
      _locationAlwaysRequired = false;
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
    if (_isBusy) return;
    final current = LatLng(position.latitude, position.longitude);
    final previous = _lastRecordedLatLng;
    _lastRecordedLatLng = current;
    _lastKnownPosition = current;
    if (previous != null) {
      unawaited(_recordCellsForMovement(previous, current));
    }
    // BG 中は UI 再計算を行わない（不可視ウィジェットの rebuild を避ける）。
    if (_appInBackground) return;
    if (_followUser) {
      _followTick++;
      notifyListeners();
    }
  }

  /// 前回位置から現在位置までを結ぶ線分が貫通する Zoom14 セル（DDA 判定）を
  /// 重複なく DB に書き込む。DB 記録は毎回即座に完了させるため、ズーム変更などの
  /// タイミングで TileOverlay を作り直せば常に最新状態が反映される。
  ///
  /// 描画更新は「記録された cell の少なくとも 1 つが画面内に存在する」場合だけ
  /// pending カウンタに加算する。画面外の cell だけを記録しても TileOverlay は
  /// 触らない（GM のタイル再取得を発火させないため）。
  /// 画面外記録分は shard キャッシュ無効化だけで十分 — 後でユーザがその領域に
  /// パンした際、`requestViewportPrefetch` が最新データを再ロードする。
  Future<void> _recordCellsForMovement(LatLng from, LatLng to) async {
    // `_onPositionUpdate` で busy チェックはしているが、
    // unawaited で起動された future が走り出すまでに `setBusy(true)` が
    // 呼ばれている可能性がある（インポート開始時の race）ので、ここでも再チェック。
    if (_isBusy) return;

    final cells = CellIndex.cellsOnSegment(from, to);

    // `from` が属するセルは前回の位置更新時に既に記録済みなので除外する。
    // これにより、同一 cell に滞在している間は記録が発生せず、
    // cell を跨ぎ越した時だけ新規セルに対して初回の記録が走る。
    final fromCell = CellIndex.latLngToIndices14(from);
    cells.remove(fromCell);

    if (cells.isEmpty) return;
    if (_isBusy) return;
    BackgroundActivityService.instance.begin();
    try {
      final counts = await _databaseRepository.recordVisitedCells14(cells);
      // 日次履歴（area3.db / area_table）も並行で更新する。
      // ただし fire-and-forget で GPS の流れを止めない。
      if (counts.newCells > 0 || counts.existingCells > 0) {
        unawaited(_databaseRepository.recordDailyArea(
          newCells: counts.newCells,
          existingCells: counts.existingCells,
        ));
      }
    } finally {
      BackgroundActivityService.instance.end();
    }
    // ===== ここから先は UI/可視化の更新。BG 中はすべてスキップ =====
    // BG 中はマップが見えないので、stats 集計やタイル再生成、ハイライト
    // 判定などをすべて省略し、CPU/IO/wakeup を最小化する。
    // 復帰時に `didChangeAppLifecycleState` で 1 回だけまとめて反映する。
    if (_appInBackground) return;

    // HUD 統計を更新（デバウンスされるので連続記録でも負荷は限定的）。
    refreshTotalStats();

    if (_isBusy) return;
    if (!_anyCellInVisibleBounds(cells)) {
      // 画面外の記録 → 描画トリガは発行しない。
      return;
    }

    _pendingRecordedCount += cells.length;
    if (_pendingRecordedCount >= _pendingFlushThreshold) {
      _flushPendingRecordings();
    }
  }

  /// 記録された cell (z=14) のいずれかが現在の可視ビューポートに入っているか。
  /// `_currentVisibleBounds` 未設定時は安全側で true (= 更新を通す) を返す。
  bool _anyCellInVisibleBounds(Iterable<(int, int)> cells) {
    final bounds = _currentVisibleBounds;
    if (bounds == null) return true;
    const double cellSize = 0.0002; // z=14 基準
    final double s = bounds.southwest.latitude;
    final double n = bounds.northeast.latitude;
    final double w = bounds.southwest.longitude;
    final double e = bounds.northeast.longitude;
    // 本アプリは国内利用想定なので日付変更線跨ぎは無視。シンプル AABB で判定。
    for (final (lat, lng) in cells) {
      final double south = lat * cellSize - 90.0;
      final double west = lng * cellSize - 180.0;
      final double north = south + cellSize;
      final double east = west + cellSize;
      if (north < s || south > n) continue;
      if (east < w || west > e) continue;
      return true;
    }
    return false;
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

  // --- 初回起動時の許可事前説明（Rationale） ---
  /// 初回起動時のみ、OS の許可ダイアログの前に「なぜ位置情報が必要か」を
  /// 説明する画面を出す必要があることを示すフラグ。UI 側でダイアログを
  /// 表示した後 `acknowledgeLocationRationale()` を呼ぶと、保留していた
  /// 位置情報許可フローが再開される。
  bool _needsLocationRationale = false;
  bool get needsLocationRationale => _needsLocationRationale;

  Completer<void>? _rationaleAck;
  static const String _kPrefLocationRationaleShown = 'location_rationale_shown';

  /// UI 側の説明ダイアログで「OK」が押されたら呼ぶ。フラグを下ろして
  /// SharedPreferences に保存し、保留中の許可フローを再開する。
  Future<void> acknowledgeLocationRationale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPrefLocationRationaleShown, true);
    } catch (_) {}
    _needsLocationRationale = false;
    final c = _rationaleAck;
    _rationaleAck = null;
    notifyListeners();
    if (c != null && !c.isCompleted) c.complete();
  }

  // --- ユーザ操作による記録 ON/OFF ---
  /// ユーザがメニュー等から「記録を停止」を選んだ場合に true 側になるフラグ。
  /// true の間は `startLocationRecording` を呼んでもストリームを開かない。
  /// SharedPreferences に永続化されており、アプリ再起動後も状態を維持する。
  bool _recordingEnabled = true;
  bool get recordingEnabled => _recordingEnabled;

  static const String _kPrefRecordingEnabled = 'recording_enabled';

  /// 記録を停止する。フラグを false にし、永続化してストリームを閉じる。
  /// 通知（foreground service）も同時に止まる。
  Future<void> stopRecording() async {
    _recordingEnabled = false;
    disposeLocationRecording();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPrefRecordingEnabled, false);
    } catch (_) {}
    notifyListeners();
  }

  /// 記録を再開する。フラグを true にし、永続化してストリームを再開。
  Future<void> startRecording() async {
    _recordingEnabled = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPrefRecordingEnabled, true);
    } catch (_) {}
    notifyListeners();
    await startLocationRecording();
  }

  Future<void> _loadRecordingEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(_kPrefRecordingEnabled);
      if (v != null) _recordingEnabled = v;
    } catch (_) {}
  }

  /// ユーザ操作（ドラッグ/ピンチ）で地図が動き始めた瞬間のフック。
  /// 以降 `onCameraIdle` が呼ばれるまでの間、TileOverlay の作り直しを
  /// 延期キューに積む（ネイティブ側のタイル再取得でジェスチャを止めない）。
  void onCameraMoveStarted() {
    _isGesturing = true;
  }

  void onCameraMove(CameraPosition position) {
    final prev = _cameraPosition;
    _cameraPosition = position;
    // bearing / tilt が目に見えて変化したら notify して、回転アイコン等の
    // UI を追従させる。target / zoom では notify しない（パン中に無駄な
    // rebuild を避けるため）。
    final bearingDelta = (position.bearing - prev.bearing).abs();
    final tiltDelta = (position.tilt - prev.tilt).abs();
    if (bearingDelta > 1.0 || tiltDelta > 1.0) {
      notifyListeners();
    }
  }

  /// 起動時に呼ぶ。SharedPreferences から前回のカメラ位置を読み出し、
  /// 存在すれば `_cameraPosition` に反映する。存在しない場合は現在地を
  /// 取得して反映する（位置情報が未許可／取得不能なら東京駅にフォールバック）。
  ///
  /// 戻り値は GoogleMap の `initialCameraPosition` に渡す位置。
  /// MapWidget は `cameraInitialized` が `true` になってから地図を描画する。
  Future<CameraPosition> initializeCameraPosition() async {
    if (_cameraInitialized) return _cameraPosition;
    // ベースマップスタイルも起動時に復元する（I/O は並行）。
    unawaited(_loadMapBaseStyle().then((_) {
      // 反映のため tick を進めて通知する（onMapCreated 前でも後でも対応できる）。
      _mapStyleTick++;
      notifyListeners();
    }));
    // タイル解像度の永続化値を復元。変更時は次の TileOverlay 再生成時に反映。
    unawaited(_loadTileResolution().then((_) {
      _refreshTileOverlay();
      notifyListeners();
    }));
    // 記録 ON/OFF の永続化値を復元。
    unawaited(_loadRecordingEnabled().then((_) {
      notifyListeners();
    }));
    // HUD 用の累計統計: まずキャッシュ（SharedPreferences）から即時復元し、
    // 続けて DB から正確値を再計算する。タスクキル直後の起動でも 0/0 にならない。
    unawaited(_loadTotalStatsFromPrefs().then((_) => _doRefreshTotalStats()));
    try {
      final prefs = await SharedPreferences.getInstance();
      final double? lat = prefs.getDouble(_kPrefCameraLat);
      final double? lng = prefs.getDouble(_kPrefCameraLng);
      final double? zoom = prefs.getDouble(_kPrefCameraZoom);
      if (lat != null && lng != null && zoom != null) {
        final double bearing = prefs.getDouble(_kPrefCameraBearing) ?? 0.0;
        final double tilt = prefs.getDouble(_kPrefCameraTilt) ?? 0.0;
        _cameraPosition = CameraPosition(
          target: LatLng(lat, lng),
          zoom: zoom,
          bearing: bearing,
          tilt: tilt,
        );
        _cameraInitialized = true;
        notifyListeners();
        return _cameraPosition;
      }
    } catch (_) {
      // SharedPreferences 失敗時はフォールバック処理に進む。
    }

    // 保存位置がない → 現在地で復帰を試みる。
    final LatLng? current = await _tryGetCurrentPosition();
    if (current != null) {
      _cameraPosition = CameraPosition(target: current, zoom: 14);
    }
    // current が null の場合はフォールバック座標が既に入っているのでそのまま使う。
    _cameraInitialized = true;
    notifyListeners();
    return _cameraPosition;
  }

  /// 現在地を取得。位置情報サービス／権限が無効な場合は null を返す。
  /// initializeCameraPosition() からのみ呼ばれる軽量メソッド。
  Future<LatLng?> _tryGetCurrentPosition() async {
    if (!(defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS)) {
      return null;
    }
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever ||
          permission == LocationPermission.unableToDetermine) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 3));
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// 現在のカメラ位置を SharedPreferences に保存する。
  /// `onCameraIdle` のタイミングから呼ばれる前提（連打抑止のため）。
  Future<void> _saveCameraPosition() async {
    if (!_cameraInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final pos = _cameraPosition;
      await prefs.setDouble(_kPrefCameraLat, pos.target.latitude);
      await prefs.setDouble(_kPrefCameraLng, pos.target.longitude);
      await prefs.setDouble(_kPrefCameraZoom, pos.zoom);
      await prefs.setDouble(_kPrefCameraBearing, pos.bearing);
      await prefs.setDouble(_kPrefCameraTilt, pos.tilt);
    } catch (_) {
      // 保存失敗時はサイレントに無視（次の onCameraIdle で再試行される）。
    }
  }

  /// カメラ操作が落ち着いたタイミングのフック。
  /// - 拡大率変化 + pending セルがあれば TileOverlay を更新
  /// - ジェスチャ中に積まれた延期リフレッシュがあればここで 1 回だけ消化
  /// - 現在のカメラ位置を SharedPreferences に保存（タスクキル後の復帰用）
  void onCameraIdle() {
    _isGesturing = false;
    final int currentZoom = _cameraPosition.zoom.floor();
    final int? prev = _lastObservedZoomLevel;
    _lastObservedZoomLevel = currentZoom;
    final bool zoomChanged = prev != null && prev != currentZoom;
    if (zoomChanged && _pendingRecordedCount > 0) {
      _flushPendingRecordings();
    } else if (_deferredRefresh) {
      _deferredRefresh = false;
      _refreshTileOverlay();
    }
    // 位置保存は onCameraIdle のタイミングなので、移動／ズーム終了時にだけ走る。
    // I/O は完全に async で、カメラ操作のレスポンスをブロックしない。
    unawaited(_saveCameraPosition());
  }

  /// ビューポートに対応する shard をまとめて DB から取り出し、
  /// `DatabaseRepository._shardCellCache` に載せる。
  /// `map_widget` 側で `GoogleMapController.getVisibleRegion()` の結果を渡す想定。
  ///
  /// `getTile` → `_queryShardCells` はキャッシュヒット時 in-memory filter で済むので、
  /// ズーム変更直後の初回タイル生成 DB 待ちを大幅に削減できる。
  void requestViewportPrefetch(LatLngBounds bounds) {
    // 可視ビューポートを最新に保つ（`_recordCellsForMovement` の可視判定に使う）。
    _currentVisibleBounds = bounds;

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

    // Activity を登録し、非同期完了時に end() を必ず呼ぶ。
    BackgroundActivityService.instance.begin();
    unawaited(_databaseRepository
        .prefetchShards(
          cellZ: cellZ,
          sLat: sLat,
          nLat: nLat,
          wLng: wLng,
          eLng: eLng,
        )
        .whenComplete(() => BackgroundActivityService.instance.end()));
  }

  /// タイルオーバーレイを更新 (再描画)。
  /// 新しい TileOverlayId に切り替わることで既存タイルキャッシュが破棄される。
  ///
  /// ジェスチャ中にこれを呼ぶと GM ネイティブ層がタイル一斉再取得を始めて
  /// 指追従がカクつくため、ジェスチャ中は `_deferredRefresh` に退避して
  /// `onCameraIdle` で 1 回だけ実行する。
  ///
  /// GPS 記録等の連続呼び出しに対しては 250ms のスロットルを設ける。
  /// 直前の refresh から 250ms 未満の場合は即座に return し、
  /// 次の flush 判定時に再評価される。
  void _refreshTileOverlay() {
    if (_isBusy) return;
    if (_isGesturing) {
      _deferredRefresh = true;
      return;
    }
    final now = DateTime.now();
    if (_lastRefreshTime != null &&
        now.difference(_lastRefreshTime!) < _refreshThrottle) {
      return;
    }
    _lastRefreshTime = now;

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

  /// 外部からリフレッシュを要求する。スロットルをバイパスする。
  void refreshMap() {
    _lastRefreshTime = null; // スロットルをリセット
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
    BackgroundActivityService.instance.begin();
    try {
      await _databaseRepository.deleteCells(_highlightCells.toList(),
          onProgress: onProgress);
    } finally {
      BackgroundActivityService.instance.end();
    }
    cancelDeleteSectionMode();
    _refreshTileOverlay();
    refreshTotalStats(immediate: true);
  }

  /// z=14 の既存データから z=3..13 の親ズームを丸ごと再構築する。
  ///
  /// ユーザシナリオ: z=14 だけしか記録されておらず、低ズームの描画が欠落
  /// している状態で呼ぶと、派生データを作り直して低ズーム描画が復活する。
  ///
  /// 処理中は busy 状態にしてタイル再描画を止め、完了後に一括で描画キャッシュを
  /// 無効化して再描画させる。
  Future<void> rebuildParentZooms({
    void Function(int processed, int total)? onProgress,
  }) async {
    setBusy(true);
    try {
      await _databaseRepository.rebuildParentZoomsFromZ14(
          onProgress: onProgress);
    } finally {
      setBusy(false);
    }
    _refreshTileOverlay();
    refreshTotalStats(immediate: true);
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
      _highlightCache[z] = <(int, int)>{};
    }

    const int baseZ = 14;
    for (final cell in _highlightCells) {
      // Zoom 14 -> add itself
      _highlightCache[14]!.add((cell.lat, cell.lng));

      // Zoom 3..13 -> add parent. cell index は非負なので `>>` は
      // `/pow(2,shift)`.floor() と等価かつ高速。
      for (int z = 3; z < baseZ; z++) {
        final int shift = baseZ - z;
        final int parentLat = cell.lat >> shift;
        final int parentLng = cell.lng >> shift;
        _highlightCache[z]!.add((parentLat, parentLng));
      }
    }
    // highlight 集合は PNG キャッシュキーに含まれないので、明示破棄する。
    _clearTilePngCache();
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

  /// タイルの画像データを生成して返すメソッド。
  ///
  /// **Option B — Skia ネイティブ PNG 方式**。
  /// `ui.PictureRecorder` → `Canvas` → `picture.toImage()` → `toByteData(PNG)`
  /// というパスで Skia のネイティブ PNG エンコーダを使う。
  /// `image` パッケージの pure-Dart `encodePng` より 5〜10 倍高速。
  ///
  /// 描画ロジックは `getTileImage` と共通化のため `_paintCellsOnCanvas` に抽出済み。
  Future<Tile> getTile(int tileX, int tileY, int? zoomDesc) async {
    final int ts = _tileResolution;

    if (_isBusy) return Tile(ts, ts, null);
    if (zoomDesc == null) return Tile(ts, ts, null);

    final int tileZ = zoomDesc;
    final int cellZ = _isManualCellSize ? _manualCellZ : tileZ.clamp(3, 14);

    final cells =
        await _databaseRepository.fetchCells(tileZ, cellZ, tileX, tileY);

    if (cells.isEmpty) return Tile(ts, ts, null);

    final bool hideStroke = shouldHideCellStroke(tileZ);
    final bool delete = isDeleteSectionMode;

    // 日付フィルタの状態はキーに含めて、切替時にキャッシュを使い回さないようにする。
    final String filterKey = _dateFilterEnabled &&
            _dateFilterStart != null &&
            _dateFilterEnd != null
        ? 'f${_dateFilterStart!.millisecondsSinceEpoch}-${_dateFilterEnd!.millisecondsSinceEpoch}'
        : 'f0';

    // キャッシュキー
    final String key =
        '$ts-$tileZ-$cellZ-$tileX-$tileY-${hideStroke ? 1 : 0}-${delete ? 1 : 0}-$filterKey';

    // content hash: (lat, lng, val, tm, p1) を混ぜる。フィルタ ON 時は tm/p1 で
    // 描画色が変わるため、タイムスタンプも hash に加える。
    int contentHash = cells.length;
    for (final c in cells) {
      contentHash = (contentHash * 1000003) ^ c.lat;
      contentHash = (contentHash * 1000003) ^ c.lng;
      contentHash = (contentHash * 1000003) ^ c.val;
      contentHash = (contentHash * 1000003) ^ c.tm;
      contentHash = (contentHash * 1000003) ^ (c.p1 ?? 0);
    }

    // z<14 で日付フィルタが ON のとき、タイル内の z14 子セルから該当する
    // 親キー集合を取得する。
    Set<(int, int)>? matchingParentKeys;
    if (_dateFilterEnabled &&
        _dateFilterStart != null &&
        _dateFilterEnd != null &&
        cellZ < 14) {
      final int startMs = _dateFilterStart!.millisecondsSinceEpoch;
      final int endMs = _dateFilterEnd!
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch;
      matchingParentKeys = await _databaseRepository.fetchMatchingParentKeys(
        tileZ: tileZ,
        parentCellZ: cellZ,
        tileX: tileX,
        tileY: tileY,
        startMs: startMs,
        endMs: endMs,
      );
      // マッチ集合もキャッシュキーに影響させる。
      contentHash = (contentHash * 1000003) ^ matchingParentKeys.length;
      for (final k in matchingParentKeys) {
        contentHash = (contentHash * 1000003) ^ k.$1;
        contentHash = (contentHash * 1000003) ^ k.$2;
      }
    }

    final cached = _tilePngCache[key];
    if (cached != null && cached.contentHash == contentHash) {
      // LRU 最新側に移動
      _tilePngCache.remove(key);
      _tilePngCache[key] = cached;
      return Tile(ts, ts, cached.png);
    }

    // --- Skia ネイティブ PNG 方式 ---
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    _paintCellsOnCanvas(
      canvas: canvas,
      cells: cells,
      ts: ts,
      tileZ: tileZ,
      cellZ: cellZ,
      tileX: tileX,
      tileY: tileY,
      hideStroke: hideStroke,
      deleteMode: delete,
      matchingParentKeys: matchingParentKeys,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(ts, ts);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    final pngBytes = byteData!.buffer.asUint8List();

    // LRU に保存（上限超過なら最古を捨てる）
    _tilePngCache[key] =
        _TilePngEntry(contentHash: contentHash, png: pngBytes);
    while (_tilePngCache.length > _tilePngCacheCap) {
      _tilePngCache.remove(_tilePngCache.keys.first);
    }

    return Tile(ts, ts, pngBytes);
  }

  /// `getTile` / `getTileImage` 共通のセル描画ロジック。
  /// Skia `Canvas` に対して直接 `drawRect` する。
  ///
  /// パフォーマンス最適化:
  /// - `pow(2, 14-cellZ)` → `1 << (14-cellZ)` に置換。
  /// - Web Mercator の Y 計算（`log`/`tan`）は同じ `lat index` に対して共通なので、
  ///   1 タイル内でユニーク lat index だけキャッシュ（描画セルが 1000 でも
  ///   実際の `log/tan` 呼び出しは数十〜数百に収まる）。
  /// - 経度方向は線形なので `lng index` から直接 pixel を 1 乗算で求める。
  /// - `HSVColor.fromAHSV(...).toColor()` は `val` の上限値までの LUT を
  ///   1 タイルあたり 1 回だけ計算して引く（セル毎の HSV→RGB 変換を排除）。
  void _paintCellsOnCanvas({
    required Canvas canvas,
    required Set<Cell> cells,
    required int ts,
    required int tileZ,
    required int cellZ,
    required int tileX,
    required int tileY,
    required bool hideStroke,
    required bool deleteMode,
    Set<(int, int)>? matchingParentKeys,
  }) {
    if (cells.isEmpty) return;

    // 日付フィルタのミリ秒レンジ（UTC 換算ではなくローカル日単位）。
    // end は当日の 23:59:59.999 まで含めるため +1 日で「次の日の 00:00」にする。
    final bool filterOn = _dateFilterEnabled &&
        _dateFilterStart != null &&
        _dateFilterEnd != null;
    final int? filterStartMs = filterOn
        ? _dateFilterStart!.millisecondsSinceEpoch
        : null;
    final int? filterEndMs = filterOn
        ? _dateFilterEnd!
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch
        : null;

    final Paint paintFill = Paint()..style = PaintingStyle.fill;
    final Paint paintStroke = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    final Paint paintHighlight = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    // フィルタ非該当セルの色（灰色、半透明）。
    final Color greyedColor = Colors.grey.withValues(alpha: 0.35);
    // フィルタ該当セルの色（val によらず単色赤）。
    const Color matchedRedColor = Color(0xFFE53935);

    final double tsD = ts.toDouble();
    final double tileOriginX = tileX * tsD;
    final double tileOriginY = tileY * tsD;

    // セルサイズ（度）。2 の冪倍なので bitshift で計算。
    final int cellShift = 14 - cellZ; // 0..11
    final double cellSize = 0.0002 * (1 << cellShift);

    // Web Mercator ワールドピクセル幅（tileZ 基準）。`tileZ` は通常 ≤ 19。
    final double tileCount = (1 << tileZ).toDouble(); // 2^tileZ
    final double worldWidthPx = tileCount * tsD;
    final double pxPerDeg = worldWidthPx / 360.0;
    // 経度方向のセル幅（pixel）は緯度によらず一定。
    final double cellWidthPx = cellSize * pxPerDeg;

    // Y (緯度) は非線形なので lat index ごとにユニーク値をキャッシュ。
    // latIdx の south edge latitude = latIdx * cellSize - 90。
    final Map<int, double> yCache = <int, double>{};
    double yForLatIdx(int latIdx) {
      final cached = yCache[latIdx];
      if (cached != null) return cached;
      final double latDeg = latIdx * cellSize - 90.0;
      final double latRad = latDeg * pi / 180.0;
      final double yTile =
          (1 - log(tan(pi / 4 + latRad / 2)) / pi) / 2 * tileCount;
      final double y = yTile * tsD;
      yCache[latIdx] = y;
      return y;
    }

    // 色 LUT。val の上限値 safeMax までを 1 度だけ HSV→RGB 変換してキャッシュ。
    // 本来は 1 セルずつ `HSVColor.fromAHSV(...).toColor()` を呼んでいた。
    final int mult = (1 << cellShift) < 1 ? 1 : (1 << cellShift);
    final int maxValue = 14 * mult;
    final int safeMax = maxValue < 1 ? 1 : maxValue;
    // LUT は 32-bit ARGB。
    final Int32List colorLut = Int32List(safeMax + 1);
    // 計算式は `_calculateCellColor` と完全一致させる:
    //   v ≤ 1*mult           → HSV(255°, 0.85, 0.40)
    //   1*mult < v ≤ 2*mult  → HSV(255°, 0.95, 0.65)
    //   2*mult < v ≤ 3*mult  → HSV(255°, 1.00, 1.00)
    //   3*mult < v ≤ safeMax → 青 → 赤 (HSV 255°→0°) S=V=1
    // ignore: deprecated_member_use
    final int v1Argb =
        HSVColor.fromAHSV(1.0, 255.0, 0.85, 0.40).toColor().value;
    // ignore: deprecated_member_use
    final int v2Argb =
        HSVColor.fromAHSV(1.0, 255.0, 0.95, 0.65).toColor().value;
    // ignore: deprecated_member_use
    final int blueArgb =
        HSVColor.fromAHSV(1.0, 255.0, 1.0, 1.0).toColor().value;
    final int t1 = mult;
    final int t2 = 2 * mult;
    final int t3 = 3 * mult;
    for (int v = 1; v <= safeMax; v++) {
      if (v <= t1) {
        colorLut[v] = v1Argb;
      } else if (v <= t2) {
        colorLut[v] = v2Argb;
      } else if (v <= t3) {
        colorLut[v] = blueArgb;
      } else if (safeMax <= t3) {
        colorLut[v] = blueArgb;
      } else {
        final double ratio = (v - t3) / (safeMax - t3);
        final double hue = 255.0 - ratio * 255.0;
        // ignore: deprecated_member_use
        colorLut[v] = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor().value;
      }
    }
    colorLut[0] = colorLut[1];

    final Set<(int, int)>? highlightSetForZ =
        deleteMode ? _highlightCache[cellZ] : null;

    for (final cell in cells) {
      // X: 経度方向は線形。
      //   longitude = lng * cellSize - 180
      //   pxFromLon = (lon + 180) * pxPerDeg = lng * cellSize * pxPerDeg
      final double left = cell.lng * cellWidthPx - tileOriginX;
      final double right = left + cellWidthPx;

      // Y: 緯度方向は非線形。
      //   緯度大 → pixel 小 (北が上)
      //   south edge = lat、north edge = lat + 1 (cell index 空間)
      final double bottom = yForLatIdx(cell.lat) - tileOriginY;
      final double top = yForLatIdx(cell.lat + 1) - tileOriginY;

      if (right <= 0 || bottom <= 0 || left >= tsD || top >= tsD) {
        continue;
      }

      final Rect r = Rect.fromLTRB(left, top, right, bottom);

      final int valIdx = cell.val <= 0
          ? 1
          : (cell.val >= safeMax ? safeMax : cell.val);
      if (filterOn) {
        // z=14 は自セルの p1/tm で判定。z<14 は親セルに該当する z14 子が
        // 含まれているか（matchingParentKeys）で判定する。
        bool match;
        if (cellZ >= 14) {
          final int? p1 = cell.p1;
          final int tm = cell.tm;
          match = ((p1 != null &&
                  p1 >= filterStartMs! &&
                  p1 < filterEndMs!) ||
              (tm >= filterStartMs! && tm < filterEndMs!));
        } else {
          match = matchingParentKeys != null &&
              matchingParentKeys.contains((cell.lat, cell.lng));
        }
        if (match) {
          paintFill.color = matchedRedColor;
        } else {
          paintFill.color = greyedColor;
        }
      } else {
        paintFill.color = Color(colorLut[valIdx]);
      }
      canvas.drawRect(r, paintFill);

      if (!hideStroke) {
        canvas.drawRect(r, paintStroke);
      }

      if (highlightSetForZ != null &&
          highlightSetForZ.contains((cell.lat, cell.lng))) {
        canvas.drawRect(r, paintHighlight);
      }
    }
  }

  /// タイル PNG キャッシュを完全に破棄する。
  /// ts / manualCellZ / delete モード状態などキー外のパラメータが変わった時に呼ぶ。
  void _clearTilePngCache() {
    _tilePngCache.clear();
  }

  /// `flutter_map` 向け: タイル画像を直接 `ui.Image` として返す。
  /// PNG エンコード/デコードのオーバーヘッドを回避する。
  Future<ui.Image> getTileImage(int tileX, int tileY, int zoomDesc) async {
    final int ts = _tileResolution;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    if (_isBusy) {
      final picture = recorder.endRecording();
      return picture.toImage(ts, ts);
    }

    final int tileZ = zoomDesc;
    final int cellZ = _isManualCellSize ? _manualCellZ : tileZ.clamp(3, 14);

    final cells =
        await _databaseRepository.fetchCells(tileZ, cellZ, tileX, tileY);

    if (cells.isNotEmpty) {
      Set<(int, int)>? matchingParentKeys;
      if (_dateFilterEnabled &&
          _dateFilterStart != null &&
          _dateFilterEnd != null &&
          cellZ < 14) {
        final int startMs = _dateFilterStart!.millisecondsSinceEpoch;
        final int endMs = _dateFilterEnd!
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch;
        matchingParentKeys =
            await _databaseRepository.fetchMatchingParentKeys(
          tileZ: tileZ,
          parentCellZ: cellZ,
          tileX: tileX,
          tileY: tileY,
          startMs: startMs,
          endMs: endMs,
        );
      }
      _paintCellsOnCanvas(
        canvas: canvas,
        cells: cells,
        ts: ts,
        tileZ: tileZ,
        cellZ: cellZ,
        tileX: tileX,
        tileY: tileY,
        hideStroke: shouldHideCellStroke(tileZ),
        deleteMode: isDeleteSectionMode,
        matchingParentKeys: matchingParentKeys,
      );
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
  ///
  /// 訪問回数 (cellValue) を以下の段階で色付けする (全段階で不透明度 100%)。
  /// 境界はズームレベルに応じて `mult = 2^(14-cellZ)` でスケールする。
  /// v=1, v=2 は HSV の彩度・明度を段階的に上げて v=3 (純粋な青) へ繋げる。
  /// （RGB lerp で白っぽいグレーを介すと彩度が落ちて違和感が出るため避ける）。
  ///   v ≤ 1*mult           → HSV(255°, 0.85, 0.40)  深いネイビー
  ///   1*mult < v ≤ 2*mult  → HSV(255°, 0.95, 0.65)  中間の青
  ///   2*mult < v ≤ 3*mult  → HSV(255°, 1.00, 1.00)  純粋な青
  ///   3*mult < v ≤ safeMax → 青 → 赤 (HSV 255°→0°) に線形補間 (S=V=1)
  ///
  /// 計算式は `tile_rasterizer_pool.dart` および本ファイル内の色 LUT 生成
  /// (`refreshTileOverlay` 周辺) と必ず揃えること。
  Color _calculateCellColor(int cellValue, int cellZ) {
    final int mult0 = pow(2, 14 - cellZ).floor();
    final int mult = mult0 < 1 ? 1 : mult0;
    final int safeMax0 = 14 * mult;
    final int safeMax = safeMax0 < 1 ? 1 : safeMax0;
    final int v = cellValue.clamp(1, safeMax);
    final int t1 = mult;
    final int t2 = 2 * mult;
    final int t3 = 3 * mult;
    if (v <= t1) {
      return HSVColor.fromAHSV(1.0, 255.0, 0.85, 0.40).toColor();
    }
    if (v <= t2) {
      return HSVColor.fromAHSV(1.0, 255.0, 0.95, 0.65).toColor();
    }
    if (v <= t3) {
      return HSVColor.fromAHSV(1.0, 255.0, 1.0, 1.0).toColor();
    }
    if (safeMax <= t3) {
      return HSVColor.fromAHSV(1.0, 255.0, 1.0, 1.0).toColor();
    }
    final double ratio = (v - t3) / (safeMax - t3);
    final double hue = 255.0 - ratio * 255.0;
    return HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();
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
    if (_isBusy) return const <CellPolygon>[];
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
          _highlightCache[cellZ]!.contains((cell.lat, cell.lng));

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

/// Google Maps ベースマップのテーマ。細かい表示項目は `MapStyleOverrides` で
/// 別途切り替えるため、ここは配色ベースのみ。
enum MapBaseStyle {
  /// Google Maps のデフォルト配色（ライト）。
  standard,

  /// ダークテーマ。ヒートマップの彩度を引き立たせる。
  dark,

  /// 衛星写真。
  satellite,

  /// 白紙マップ（地物・ラベル全て非表示）。
  blank,
}

/// マップに重ねる個別表示項目のトグル。全て true がデフォルト（標準表示）。
/// UI 側の設定画面でユーザが個別にオンオフする。
class MapStyleOverrides {
  final bool showPoiBusiness; // 店舗・商業施設
  final bool showPoiPark; // 公園
  final bool showPoiAttraction; // 観光地
  final bool showPoiGovernment; // 官公庁
  final bool showPoiMedical; // 病院等
  final bool showPoiSchool; // 学校
  final bool showPoiPlaceOfWorship; // 宗教施設
  final bool showPoiSportsComplex; // 運動施設
  final bool showTransitLine; // 鉄道路線・バス路線の線
  final bool showRailwayStation; // 鉄道駅
  final bool showBusStation; // バス停
  final bool showAirport; // 空港
  final bool showRoadLabels; // 道路ラベル
  final bool showAdminLabels; // 地名・境界ラベル

  const MapStyleOverrides({
    this.showPoiBusiness = true,
    this.showPoiPark = true,
    this.showPoiAttraction = true,
    this.showPoiGovernment = true,
    this.showPoiMedical = true,
    this.showPoiSchool = true,
    this.showPoiPlaceOfWorship = true,
    this.showPoiSportsComplex = true,
    this.showTransitLine = true,
    this.showRailwayStation = true,
    this.showBusStation = true,
    this.showAirport = true,
    this.showRoadLabels = true,
    this.showAdminLabels = true,
  });

  MapStyleOverrides copyWith({
    bool? showPoiBusiness,
    bool? showPoiPark,
    bool? showPoiAttraction,
    bool? showPoiGovernment,
    bool? showPoiMedical,
    bool? showPoiSchool,
    bool? showPoiPlaceOfWorship,
    bool? showPoiSportsComplex,
    bool? showTransitLine,
    bool? showRailwayStation,
    bool? showBusStation,
    bool? showAirport,
    bool? showRoadLabels,
    bool? showAdminLabels,
  }) {
    return MapStyleOverrides(
      showPoiBusiness: showPoiBusiness ?? this.showPoiBusiness,
      showPoiPark: showPoiPark ?? this.showPoiPark,
      showPoiAttraction: showPoiAttraction ?? this.showPoiAttraction,
      showPoiGovernment: showPoiGovernment ?? this.showPoiGovernment,
      showPoiMedical: showPoiMedical ?? this.showPoiMedical,
      showPoiSchool: showPoiSchool ?? this.showPoiSchool,
      showPoiPlaceOfWorship:
          showPoiPlaceOfWorship ?? this.showPoiPlaceOfWorship,
      showPoiSportsComplex: showPoiSportsComplex ?? this.showPoiSportsComplex,
      showTransitLine: showTransitLine ?? this.showTransitLine,
      showRailwayStation: showRailwayStation ?? this.showRailwayStation,
      showBusStation: showBusStation ?? this.showBusStation,
      showAirport: showAirport ?? this.showAirport,
      showRoadLabels: showRoadLabels ?? this.showRoadLabels,
      showAdminLabels: showAdminLabels ?? this.showAdminLabels,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'showPoiBusiness': showPoiBusiness,
        'showPoiPark': showPoiPark,
        'showPoiAttraction': showPoiAttraction,
        'showPoiGovernment': showPoiGovernment,
        'showPoiMedical': showPoiMedical,
        'showPoiSchool': showPoiSchool,
        'showPoiPlaceOfWorship': showPoiPlaceOfWorship,
        'showPoiSportsComplex': showPoiSportsComplex,
        'showTransitLine': showTransitLine,
        'showRailwayStation': showRailwayStation,
        'showBusStation': showBusStation,
        'showAirport': showAirport,
        'showRoadLabels': showRoadLabels,
        'showAdminLabels': showAdminLabels,
      };

  factory MapStyleOverrides.fromJson(Map json) {
    bool get(String key, bool def) {
      final v = json[key];
      if (v is bool) return v;
      return def;
    }

    return MapStyleOverrides(
      showPoiBusiness: get('showPoiBusiness', true),
      showPoiPark: get('showPoiPark', true),
      showPoiAttraction: get('showPoiAttraction', true),
      showPoiGovernment: get('showPoiGovernment', true),
      showPoiMedical: get('showPoiMedical', true),
      showPoiSchool: get('showPoiSchool', true),
      showPoiPlaceOfWorship: get('showPoiPlaceOfWorship', true),
      showPoiSportsComplex: get('showPoiSportsComplex', true),
      showTransitLine: get('showTransitLine', true),
      showRailwayStation: get('showRailwayStation', true),
      showBusStation: get('showBusStation', true),
      showAirport: get('showAirport', true),
      showRoadLabels: get('showRoadLabels', true),
      showAdminLabels: get('showAdminLabels', true),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapStyleOverrides &&
          showPoiBusiness == other.showPoiBusiness &&
          showPoiPark == other.showPoiPark &&
          showPoiAttraction == other.showPoiAttraction &&
          showPoiGovernment == other.showPoiGovernment &&
          showPoiMedical == other.showPoiMedical &&
          showPoiSchool == other.showPoiSchool &&
          showPoiPlaceOfWorship == other.showPoiPlaceOfWorship &&
          showPoiSportsComplex == other.showPoiSportsComplex &&
          showTransitLine == other.showTransitLine &&
          showRailwayStation == other.showRailwayStation &&
          showBusStation == other.showBusStation &&
          showAirport == other.showAirport &&
          showRoadLabels == other.showRoadLabels &&
          showAdminLabels == other.showAdminLabels;

  @override
  int get hashCode => Object.hash(
        showPoiBusiness,
        showPoiPark,
        showPoiAttraction,
        showPoiGovernment,
        showPoiMedical,
        showPoiSchool,
        showPoiPlaceOfWorship,
        showPoiSportsComplex,
        showTransitLine,
        showRailwayStation,
        showBusStation,
        showAirport,
        showRoadLabels,
        showAdminLabels,
      );
}

/// 旧 "ランドマーク非表示" 定義は `MapStyleOverrides` で同等を再現できるため撤去。

/// ダークテーマの JSON rule 群（lazy に decode した結果をキャッシュ）。
final List<Map<String, dynamic>> _kDarkRules = () {
  final decoded = jsonDecode(_kDarkStyleJson) as List<dynamic>;
  return decoded.cast<Map<String, dynamic>>();
}();

/// ダークテーマの JSON。既存 `assets/mapstyle.json` と同等の配色を内蔵する
/// （asset 読み込みを挟まず即適用できるようにするため）。
///
/// **注意**: 以前は `featureType: all / elementType: labels` で全ラベルを
/// 一括非表示にしていたが、これだと駅名など重要なラベルまで消える副作用が
/// あるため、ここでは配色のみを指定し、表示/非表示はユーザの詳細設定
/// （`MapStyleOverrides`）に委ねる。
const String _kDarkStyleJson = '''
[
  {
    "elementType": "geometry",
    "stylers": [{ "color": "#12181F" }]
  },
  {
    "elementType": "labels.text.stroke",
    "stylers": [{ "color": "#242f3e" }]
  },
  {
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#9ca5b3" }]
  },
  {
    "featureType": "administrative.locality",
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#d59563" }]
  },
  {
    "featureType": "poi.park",
    "elementType": "geometry",
    "stylers": [{ "color": "#263c3f" }]
  },
  {
    "featureType": "poi.park",
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#6b9a76" }]
  },
  {
    "featureType": "road",
    "elementType": "geometry",
    "stylers": [{ "color": "#38414e" }]
  },
  {
    "featureType": "road",
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#9ca5b3" }]
  },
  {
    "featureType": "road.highway",
    "elementType": "geometry",
    "stylers": [{ "color": "#6b6b6b" }]
  },
  {
    "featureType": "road.highway",
    "elementType": "geometry.stroke",
    "stylers": [{ "color": "#1f2835" }]
  },
  {
    "featureType": "road.highway",
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#c9c9c9" }]
  },
  {
    "featureType": "transit",
    "elementType": "geometry",
    "stylers": [{ "color": "#9a9a9a" }]
  },
  {
    "featureType": "transit.line",
    "elementType": "geometry",
    "stylers": [{ "color": "#3a6c4e" }]
  },
  {
    "featureType": "transit.station.airport",
    "elementType": "geometry",
    "stylers": [{ "color": "#3f3f3f" }]
  },
  {
    "featureType": "transit.station",
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#d59563" }]
  },
  {
    "featureType": "water",
    "elementType": "geometry",
    "stylers": [{ "color": "#17263c" }]
  },
  {
    "featureType": "water",
    "elementType": "labels.text.fill",
    "stylers": [{ "color": "#515c6d" }]
  },
  {
    "featureType": "water",
    "elementType": "labels.text.stroke",
    "stylers": [{ "color": "#17263c" }]
  }
]
''';

/// Per-Tile PNG LRU キャッシュのエントリ。
/// `contentHash` は fetchCells で得たセル配列内容のハッシュ。
/// これが前回と一致すれば、そのタイルは再生成不要 (= 変更なし) と判断できる。
class _TilePngEntry {
  const _TilePngEntry({required this.contentHash, required this.png});
  final int contentHash;
  final Uint8List png;
}

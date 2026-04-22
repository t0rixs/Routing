import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/cell.dart';
import '../models/db_key.dart';

/// アプリ共通の DB ディレクトリ。モバイルは `sqflite.getDatabasesPath()`、
/// macOS / Linux / Windows では `ApplicationSupport/routing/databases` を使う。
Future<String> appDatabasesPath() async {
  if (!kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    final support = await getApplicationSupportDirectory();
    final dbDir = Directory(p.join(support.path, 'databases'));
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }
    return dbDir.path;
  }
  return await getDatabasesPath();
}

/// SQLiteデータベースへのアクセスを担当するリポジトリ
class DatabaseRepository {
  // シングルトン化 (アプリ全体でDB接続を管理するため)
  static final DatabaseRepository _instance = DatabaseRepository._internal();
  factory DatabaseRepository() => _instance;
  DatabaseRepository._internal();

  // DBインスタンスのキャッシュ (開いたDBを再利用)
  final Map<DBKey, Database> _openDatabases = {};
  // DBのモードキャッシュ (true=readOnly, false=writable)
  final Map<DBKey, bool> _openDbModes = {};

  /// shard 単位のセルキャッシュ。viewport プリフェッチで埋まり、
  /// per-tile の `_queryShardCells` が in-memory フィルタで返せるようにする。
  /// GPS 記録時は該当 shard のみ `remove` することで fine-grained に無効化する。
  final Map<DBKey, List<Cell>> _shardCellCache = {};
  // 同一 shard への同時 prefetch 重複起動を防ぐ
  final Map<DBKey, Future<List<Cell>>> _shardPrefetchInFlight = {};

  /// データベースディレクトリのパスを取得
  Future<String> get _dbDirectoryPath async {
    return await appDatabasesPath();
  }

  /// 特定のキーに対応するデータベースを開く
  Future<Database?> openDB(DBKey key, {bool readOnly = true}) async {
    final dbDir = await _dbDirectoryPath;
    String filename = key.toFileName();
    String path = p.join(dbDir, filename);

    // キャッシュチェック
    if (_openDatabases.containsKey(key)) {
      final db = _openDatabases[key]!;
      final currentMode = _openDbModes[key] ?? true;

      if (db.isOpen) {
        if (!readOnly && currentMode) {
          await db.close();
          _openDatabases.remove(key);
          _openDbModes.remove(key);
        } else {
          return db;
        }
      } else {
        _openDatabases.remove(key);
        _openDbModes.remove(key);
      }
    }

    // ファイル存在確認 (.db 優先、無ければ .sqlite を探す)
    final fileDb = File(path);
    if (!await fileDb.exists()) {
      // .db が無い場合、.sqlite をチェック
      // key.toFileName() は通常 .db を返すと仮定
      if (filename.endsWith('.db')) {
        final sqliteName = filename.replaceAll(RegExp(r'\.db$'), '.sqlite');
        final sqlitePath = p.join(dbDir, sqliteName);
        if (await File(sqlitePath).exists()) {
          path = sqlitePath; // .sqlite を採用
        }
      }

      // それでも無くてReadOnlyなら戻る
      if (!await File(path).exists() && readOnly) {
        return null;
      }
    }

    try {
      final db = await openDatabase(
        path,
        readOnly: readOnly,
        // WALモードを明示的に有効化またはチェックポイント設定などを考慮しても良いが、
        // とりあえず単一ファイルへの接続として開く
        version: readOnly ? null : 1,
        onCreate: readOnly
            ? null
            : (db, version) async {
                await db.execute(
                    'CREATE TABLE IF NOT EXISTS heatmap_table (lat INTEGER, lng INTEGER, val INTEGER, tm INTEGER, p1 INTEGER, PRIMARY KEY (lat, lng))');
                await db.execute(
                    'CREATE INDEX IF NOT EXISTS idx_lat_lng ON heatmap_table (lat, lng)');
              },
      );
      _openDatabases[key] = db;
      _openDbModes[key] = readOnly;
      return db;
    } catch (e) {
      debugPrint('Error opening database $key: $e');
      return null;
    }
  }

  /// 指定された範囲 (Tile) のセルデータを取得
  /// [tileZ]: タイルのズームレベル
  /// [cellZ]: データのズームレベル (通常14固定またはtileZに依存)
  /// [x], [y]: タイル座標
  Future<Set<Cell>> fetchCells(int tileZ, int cellZ, int x, int y) async {
    Set<Cell> cells = {};

    try {
      // 1. タイルの緯度経度範囲を計算
      final bounds = _tileToLatLngBounds(tileZ, x, y);

      // 2. セルサイズを計算 (既存ロジック: 0.0002 * 2^(14 - cellZ))
      // Zoom14基準で0.0002度
      final double cellSize = (0.0002 * pow(2, 14 - cellZ)).toDouble();

      // 3. 検索範囲のインデックス (s, n, w, e) を計算
      // 東端の補正処理
      double eastLon = bounds.northeast.longitude;
      if (eastLon <= -180.0 + 1e-12) eastLon = 180.0;
      final double eastForIndex = eastLon - 1e-9;
      final double northForIndex = bounds.northeast.latitude - 1e-9;

      int s = ((bounds.southwest.latitude + 90) / cellSize).floor();
      int n = ((northForIndex + 90) / cellSize).floor();
      int w = ((bounds.southwest.longitude + 180) / cellSize).floor();
      int e = ((eastForIndex + 180) / cellSize).floor();

      // 4. シャード (DBKey) の範囲を特定 (1000セル単位)
      int dbLatStart = s ~/ 1000;
      int dbLatEnd = n ~/ 1000;
      int dbLngStart = w ~/ 1000;
      int dbLngEnd = e ~/ 1000;

      // debugPrint('Fetching cells: Tile($tileZ, $x, $y) -> Index($s-$n, $w-$e) -> Shard($dbLatStart-$dbLatEnd, $dbLngStart-$dbLngEnd)');

      // 5. 各DBからデータを並列に取得する（sqflite は native 側 I/O スレッドで
      //    並行実行できるため、シャードごとの逐次 await を並列化するだけで
      //    チャネル RTT 分の待ちを削減できる）。
      final futures = <Future<List<Cell>>>[];
      for (int dblat = dbLatStart; dblat <= dbLatEnd; dblat++) {
        for (int dblng = dbLngStart; dblng <= dbLngEnd; dblng++) {
          final dbKey = DBKey(cellZ, dblat, dblng);
          futures.add(_queryShardCells(dbKey, s, n, w, e));
        }
      }
      final chunks = await Future.wait(futures);
      for (final chunk in chunks) {
        cells.addAll(chunk);
      }
    } catch (e) {
      debugPrint('Error in fetchCells: $e');
    }

    return cells;
  }

  /// 単一シャードから境界内のセルを取得する（fetchCells 並列化用のヘルパ）。
  ///
  /// `_shardCellCache` にヒットした場合は DB に行かず in-memory filter のみ返す。
  /// ミス時は従来通り bound 付き SELECT（fallback）を実行するが、
  /// prefetchShards が完了していない初回や、非常に巨大な shard のセーフティネット。
  Future<List<Cell>> _queryShardCells(
      DBKey key, int s, int n, int w, int e) async {
    final cached = _shardCellCache[key];
    if (cached != null) {
      return [
        for (final c in cached)
          if (c.lat >= s && c.lat <= n && c.lng >= w && c.lng <= e) c
      ];
    }
    final db = await openDB(key, readOnly: true);
    if (db == null) return const <Cell>[];
    try {
      final List<Map<String, dynamic>> res = await db.query(
        'heatmap_table',
        where: 'lat >= ? AND lat <= ? AND lng >= ? AND lng <= ?',
        whereArgs: [s, n, w, e],
      );
      return [for (final row in res) Cell.fromSqlite(row)];
    } catch (err) {
      debugPrint('Shard query error $key: $err');
      return const <Cell>[];
    }
  }

  /// viewport 内のセル領域に必要な全シャードを先読みしてメモリキャッシュする。
  ///
  /// `cellZ` はセルのズーム（自動モードなら `floor(mapZoom).clamp(3,14)`、
  /// 手動モードなら `_manualCellZ`）。`[sLat..nLat] × [wLng..eLng]` は
  /// セルインデックス空間の包含範囲。
  Future<void> prefetchShards({
    required int cellZ,
    required int sLat,
    required int nLat,
    required int wLng,
    required int eLng,
  }) async {
    final int dbLatStart = sLat ~/ 1000;
    final int dbLatEnd = nLat ~/ 1000;
    final int dbLngStart = wLng ~/ 1000;
    final int dbLngEnd = eLng ~/ 1000;

    final List<Future<void>> futures = [];
    for (int dblat = dbLatStart; dblat <= dbLatEnd; dblat++) {
      for (int dblng = dbLngStart; dblng <= dbLngEnd; dblng++) {
        final key = DBKey(cellZ, dblat, dblng);
        if (_shardCellCache.containsKey(key)) continue;
        futures.add(_prefetchSingleShard(key));
      }
    }
    if (futures.isEmpty) return;
    await Future.wait(futures);
  }

  Future<void> _prefetchSingleShard(DBKey key) async {
    if (_shardCellCache.containsKey(key)) return;
    final existing = _shardPrefetchInFlight[key];
    if (existing != null) {
      await existing;
      return;
    }
    final future = _loadEntireShard(key);
    _shardPrefetchInFlight[key] = future;
    try {
      final cells = await future;
      _shardCellCache[key] = cells;
    } finally {
      _shardPrefetchInFlight.remove(key);
    }
  }

  Future<List<Cell>> _loadEntireShard(DBKey key) async {
    final db = await openDB(key, readOnly: true);
    if (db == null) return const <Cell>[];
    try {
      final List<Map<String, dynamic>> res = await db.query(
        'heatmap_table',
        columns: ['lat', 'lng', 'val', 'tm', 'p1'],
      );
      return [for (final row in res) Cell.fromSqlite(row)];
    } catch (err) {
      debugPrint('Shard prefetch error $key: $err');
      return const <Cell>[];
    }
  }

  void _invalidateShardForCell(int z, int lat, int lng) {
    final key = DBKey(z, lat ~/ 1000, lng ~/ 1000);
    _shardCellCache.remove(key);
  }

  /// 指定されたインデックスの単一セルを取得
  Future<Cell?> getCell(int cellZ, int latIndex, int lngIndex) async {
    try {
      int dbLat = latIndex ~/ 1000;
      int dbLng = lngIndex ~/ 1000;

      final dbKey = DBKey(cellZ, dbLat, dbLng);
      final db = await openDB(dbKey, readOnly: true);

      if (db == null) return null;

      final List<Map<String, dynamic>> res = await db.query(
        'heatmap_table',
        where: 'lat = ? AND lng = ?',
        whereArgs: [latIndex, lngIndex],
      );

      if (res.isNotEmpty) {
        return Cell.fromSqlite(res.first);
      }
    } catch (e) {
      debugPrint('Error fetching specific cell: $e');
    }
    return null;
  }

  /// タイル座標を緯度経度範囲に変換 (Web Mercator)
  LatLngBounds _tileToLatLngBounds(int zoom, int x, int y) {
    double n = pow(2.0, zoom).toDouble();
    double lonDeg = x / n * 360.0 - 180.0;
    double latRad = atan(sinh(pi * (1 - 2 * y / n)));
    double latDeg = latRad * 180.0 / pi;

    double lonDegNext = (x + 1) / n * 360.0 - 180.0;
    double latRadNext = atan(sinh(pi * (1 - 2 * (y + 1) / n)));
    double latDegNext = latRadNext * 180.0 / pi;

    // Google Mapsは (SouthWest, NorthEast) で管理
    // Y座標は上が0なので、yが小さい方が北(Lat大)、yが大きい方が南(Lat小)
    return LatLngBounds(
      southwest: LatLng(latDegNext, lonDeg),
      northeast: LatLng(latDeg, lonDegNext),
    );
  }

  /// sinh (双曲線正弦)
  double sinh(double x) {
    return (exp(x) - exp(-x)) / 2;
  }

  /// 起動時に既存のDBファイル一覧をスキャンしてログ出力 (デバッグ用)
  /// macOS / Linux / Windows では書き込み権限も付与する
  Future<void> scanExistingDatabases() async {
    final dbPath = await _dbDirectoryPath;
    final dir = Directory(dbPath);
    if (!await dir.exists()) return;

    final files = dir.listSync();
    debugPrint('--- DatabaseRepository: Scan Existing Files ---');
    for (var f in files) {
      if (f is File && (f.path.endsWith('.db') || f.path.endsWith('.sqlite'))) {
        debugPrint('Found DB: ${p.basename(f.path)} Size: ${await f.length()}');
        // macOS sandbox 環境でファイルが読み取り専用になるのを防止
        if (!kIsWeb && (Platform.isMacOS || Platform.isLinux)) {
          try {
            await Process.run('chmod', ['644', f.path]);
          } catch (_) {}
        }
      }
    }
    debugPrint('--- Scan Complete ---');
  }

  /// 全ての開いているDBを閉じる
  Future<void> closeAll() async {
    for (var db in _openDatabases.values) {
      await db.close();
    }
    _openDatabases.clear();
    _openDbModes.clear();
    _shardCellCache.clear();
    _shardPrefetchInFlight.clear();
  }

  /// 指定された時間範囲に含まれるセルを全DBから検索して取得 (Zoom 14 と仮定)
  Future<List<Cell>> fetchCellsByTimeRange(int startTime, int endTime) async {
    List<Cell> results = [];
    final dbDirPath = await _dbDirectoryPath;
    final dbDir = Directory(dbDirPath);
    if (!await dbDir.exists()) {
      debugPrint('DB Directory not found: $dbDirPath');
      return [];
    }

    final files = dbDir.listSync();
    debugPrint('Found ${files.length} files in DB directory.');

    // 時間範囲を正規化
    final int start = min(startTime, endTime);
    final int end = max(startTime, endTime);

    // 正規表現でファイル名をパース: hm_14_{lat}_{lng}.db または .sqlite
    final RegExp shardPattern = RegExp(r'^hm_14_(-?\d+)_(-?\d+)\.(db|sqlite)$');

    for (var f in files) {
      if (f is! File) continue;

      final name = p.basename(f.path);
      final match = shardPattern.firstMatch(name);

      if (match != null) {
        // Zoom 14 のシャードのみ対象
        try {
          final db = await openDatabase(f.path, readOnly: true);
          final List<Map<String, dynamic>> res = await db.query(
            'heatmap_table',
            where: 'tm >= ? AND tm <= ?',
            whereArgs: [start, end],
          );

          if (res.isNotEmpty) {
            debugPrint('Found ${res.length} cells in ${f.path}');
          }

          for (final row in res) {
            results.add(Cell.fromSqlite(row));
          }
          await db.close();
        } catch (e) {
          debugPrint('Error querying DB ${f.path}: $e');
        }
      }
    }
    debugPrint('Total cells found in range: ${results.length}');
    return results;
  }

  /// 区間削除等のための削除処理
  /// [targetCells] は Zoom 14 のセルリストと仮定
  Future<void> deleteCells(List<Cell> targetCells,
      {Function(int, int)? onProgress}) async {
    const int baseZ = 14;
    int processedCount = 0;
    int totalCount = targetCells.length;

    for (final cell in targetCells) {
      // 1. MinUnit (Zoom 14) の削除
      // ターゲット自体を削除 (val=0扱い、レコード削除)
      await _updateCellVal(baseZ, cell.lat, cell.lng, 0, forceDelete: true);

      // 2. 親セル (Zoom 3-13) の減算
      for (int z = 3; z < baseZ; z++) {
        // 親の座標計算: 2^(14-z) で割る
        final double divisor = pow(2, baseZ - z).toDouble();
        final int parentLat = (cell.lat / divisor).floor();
        final int parentLng = (cell.lng / divisor).floor();

        await _decrementCellVal(z, parentLat, parentLng, cell.val);
      }

      processedCount++;
      if (onProgress != null) {
        onProgress(processedCount, totalCount);
      }
    }
  }

  /// 指定座標のセルの値を更新 (0以下なら削除)
  Future<void> _updateCellVal(int z, int lat, int lng, int newVal,
      {bool forceDelete = false}) async {
    final dbLat = lat ~/ 1000;
    final dbLng = lng ~/ 1000;
    final key = DBKey(z, dbLat, dbLng);

    // 書き込みモードで開く
    final db = await openDB(key, readOnly: false);
    if (db == null) return;

    if (newVal <= 0 || forceDelete) {
      await db.delete('heatmap_table',
          where: 'lat = ? AND lng = ?', whereArgs: [lat, lng]);
    } else {
      // update用：存在しない場合はInsertも考慮すべきだが、
      // 今回のフローでは「存在するセルの値を減らす」のがメインなのでUpdateのみ。
      // もしInsertが必要なら別途実装。
      await db.update('heatmap_table', {'val': newVal},
          where: 'lat = ? AND lng = ?', whereArgs: [lat, lng]);
    }
    _invalidateShardForCell(z, lat, lng);
  }

  /// 移動に伴い通過した Zoom14 セル（重複なし）を記録する。各セルは val を 1 増やし、親ズームも更新する。
  Future<void> recordVisitedCells14(Set<(int, int)> cellIndices) async {
    if (cellIndices.isEmpty) return;
    const int baseZ = 14;
    for (final (lat, lng) in cellIndices) {
      await _incrementCellVal(baseZ, lat, lng, 1);
      for (int z = 3; z < baseZ; z++) {
        final double divisor = pow(2, baseZ - z).toDouble();
        final int parentLat = (lat / divisor).floor();
        final int parentLng = (lng / divisor).floor();
        await _incrementCellVal(z, parentLat, parentLng, 1);
      }
    }
  }

  Future<void> _incrementCellVal(int z, int lat, int lng, int delta) async {
    final dbLat = lat ~/ 1000;
    final dbLng = lng ~/ 1000;
    final key = DBKey(z, dbLat, dbLng);
    final db = await openDB(key, readOnly: false);
    if (db == null) return;

    final int now = DateTime.now().millisecondsSinceEpoch;
    try {
      final List<Map<String, dynamic>> res = await db.query(
        'heatmap_table',
        columns: ['val', 'p1'],
        where: 'lat = ? AND lng = ?',
        whereArgs: [lat, lng],
      );

      if (res.isEmpty) {
        await db.insert('heatmap_table', {
          'lat': lat,
          'lng': lng,
          'val': delta,
          'tm': now,
          'p1': now,
        });
      } else {
        final int currentVal = res.first['val'] as int;
        final int? p1 = res.first['p1'] as int?;
        final Map<String, dynamic> updateMap = {
          'val': currentVal + delta,
          'tm': now,
        };
        if (p1 == null || p1 <= 0) {
          updateMap['p1'] = now;
        }
        await db.update(
          'heatmap_table',
          updateMap,
          where: 'lat = ? AND lng = ?',
          whereArgs: [lat, lng],
        );
      }
    } catch (e) {
      debugPrint('Error incrementing cell z=$z lat=$lat lng=$lng: $e');
    }
    _invalidateShardForCell(z, lat, lng);
  }

  /// 指定セルから値を引く
  Future<void> _decrementCellVal(int z, int lat, int lng, int diff) async {
    final dbLat = lat ~/ 1000;
    final dbLng = lng ~/ 1000;
    final key = DBKey(z, dbLat, dbLng);
    final db = await openDB(key, readOnly: false);
    if (db == null) return;

    try {
      final List<Map<String, dynamic>> res = await db.query('heatmap_table',
          columns: ['val'],
          where: 'lat = ? AND lng = ?',
          whereArgs: [lat, lng]);

      if (res.isNotEmpty) {
        int currentVal = res.first['val'] as int;
        int nextVal = currentVal - diff;
        if (nextVal <= 0) {
          await db.delete('heatmap_table',
              where: 'lat = ? AND lng = ?', whereArgs: [lat, lng]);
        } else {
          await db.update('heatmap_table', {'val': nextVal},
              where: 'lat = ? AND lng = ?', whereArgs: [lat, lng]);
        }
      }
    } catch (e) {
      debugPrint('Error decrementing cell: $e');
    }
    _invalidateShardForCell(z, lat, lng);
  }
}

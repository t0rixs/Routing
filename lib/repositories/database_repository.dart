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

  /// 親ズーム (z=3..13) 向けの write-behind バッファ。
  ///
  /// z=14 は「記録の真実」なので GPS tick 毎に即書き込みするが、
  /// 親ズームは z=14 から機械的に導出できる派生データなので、
  /// 1 GPS tick で 11 個の親 DB へ都度書き込む必要はない。
  /// ここに蓄積しておき、
  ///   (a) その shard を読み出す直前 (`fetchCells` / `prefetchShards` / `getCell`)
  ///   (b) `closeAll()` 等で明示 flush 要求されたとき
  /// にまとめて書き出す。
  ///
  /// これにより 1 GPS tick あたりのプラットフォームチャネル往復が
  /// 「z=14 1 shard × 2 RTT」のみに圧縮される（従来は 12 × 2 = 24 RTT）。
  /// GPS 記録は止まらない（z=14 は常に即時反映）。
  final Map<DBKey, Map<(int, int), int>> _pendingParentDeltas = {};

  /// インポート等で DB ファイルを差し替える期間中、書き込みを完全停止するフラグ。
  /// `true` の間、recordVisitedCells14 / deleteCells / 内部の _increment/_decrement
  /// /_updateCellVal は即座に return する。これがないと `closeAll()` 直後の
  /// in-flight な書き込み（unawaited で起動された `_recordCellsForMovement`
  /// など）が新しい DB ファイルを `openDatabase(readOnly:false)` で勝手に
  /// 再生成してしまい、Isolate でこれから書き出す .db と衝突する。
  /// またその過程で SQLITE_READONLY_DBMOVED が大量発生し、
  /// `debugPrint` 経由でメインスレッドのログ I/O を飽和させる。
  bool _writesPaused = false;
  bool get isWritesPaused => _writesPaused;

  /// 書き込みを停止する。`closeAll()` 内で自動的に呼ばれる。
  void pauseWrites() {
    _writesPaused = true;
  }

  /// 書き込みを再開する。インポート完了後 `scanExistingDatabases()` の末尾で
  /// 自動的に呼ばれる。手動でも呼べる。
  void resumeWrites() {
    _writesPaused = false;
  }

  /// データベースディレクトリのパスを取得
  Future<String> get _dbDirectoryPath async {
    return await appDatabasesPath();
  }

  /// 特定のキーに対応するデータベースを開く
  ///
  /// `_writesPaused == true` の状態で `readOnly:false` を要求された場合は、
  /// インポート isolate が DB ファイルを差し替えている最中の可能性があるので
  /// 即座に `null` を返す（呼び出し元の write は no-op になる）。
  Future<Database?> openDB(DBKey key, {bool readOnly = true}) async {
    if (_writesPaused && !readOnly) {
      return null;
    }
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
      // cellZ<14 の shard に pending な親 delta がある場合はここで先に flush する。
      // flush→キャッシュ無効化→SELECT で必ず最新が反映される。
      final futures = <Future<List<Cell>>>[];
      for (int dblat = dbLatStart; dblat <= dbLatEnd; dblat++) {
        for (int dblng = dbLngStart; dblng <= dbLngEnd; dblng++) {
          final dbKey = DBKey(cellZ, dblat, dblng);
          if (cellZ < 14 && _pendingParentDeltas.containsKey(dbKey)) {
            await _flushPendingForShard(dbKey);
          }
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

  /// タイル領域に含まれる z14 セルのうち、`p1`（初回訪問）または
  /// `tm`（最終訪問）が `[startMs, endMs)` の範囲に入るものを対象に、
  /// 親ズーム `parentCellZ` におけるセルインデックス `(lat, lng)` の
  /// 集合を返す。
  ///
  /// 日付フィルタ有効時の z<14 表示で、「どの親セルに該当する z14 子セルが
  /// 含まれるか」を高速に判定するために使う。
  Future<Set<(int, int)>> fetchMatchingParentKeys({
    required int tileZ,
    required int parentCellZ,
    required int tileX,
    required int tileY,
    required int startMs,
    required int endMs,
  }) async {
    final result = <(int, int)>{};
    if (parentCellZ >= 14) return result;
    try {
      final bounds = _tileToLatLngBounds(tileZ, tileX, tileY);
      const double cellSize14 = 0.0002;
      double eastLon = bounds.northeast.longitude;
      if (eastLon <= -180.0 + 1e-12) eastLon = 180.0;
      final double eastForIndex = eastLon - 1e-9;
      final double northForIndex = bounds.northeast.latitude - 1e-9;

      final int s = ((bounds.southwest.latitude + 90) / cellSize14).floor();
      final int n = ((northForIndex + 90) / cellSize14).floor();
      final int w = ((bounds.southwest.longitude + 180) / cellSize14).floor();
      final int e = ((eastForIndex + 180) / cellSize14).floor();

      final int dbLatStart = s ~/ 1000;
      final int dbLatEnd = n ~/ 1000;
      final int dbLngStart = w ~/ 1000;
      final int dbLngEnd = e ~/ 1000;

      final int shift = 14 - parentCellZ;

      final futures = <Future<void>>[];
      for (int dblat = dbLatStart; dblat <= dbLatEnd; dblat++) {
        for (int dblng = dbLngStart; dblng <= dbLngEnd; dblng++) {
          final key = DBKey(14, dblat, dblng);
          futures.add(() async {
            final db = await openDB(key, readOnly: true);
            if (db == null) return;
            try {
              final rows = await db.query(
                'heatmap_table',
                columns: ['lat', 'lng'],
                where:
                    'lat >= ? AND lat <= ? AND lng >= ? AND lng <= ? AND '
                    '((p1 IS NOT NULL AND p1 >= ? AND p1 < ?) OR (tm >= ? AND tm < ?))',
                whereArgs: [s, n, w, e, startMs, endMs, startMs, endMs],
              );
              for (final r in rows) {
                final int lat14 = r['lat'] as int;
                final int lng14 = r['lng'] as int;
                result.add((lat14 >> shift, lng14 >> shift));
              }
            } catch (err) {
              debugPrint('fetchMatchingParentKeys shard error $key: $err');
            }
          }());
        }
      }
      await Future.wait(futures);
    } catch (e) {
      debugPrint('Error in fetchMatchingParentKeys: $e');
    }
    return result;
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
        // 親ズームの場合は pending delta を先に flush してから prefetch する。
        if (cellZ < 14 && _pendingParentDeltas.containsKey(key)) {
          await _flushPendingForShard(key);
        }
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

  /// 指定されたインデックスの単一セルを取得
  Future<Cell?> getCell(int cellZ, int latIndex, int lngIndex) async {
    try {
      int dbLat = latIndex ~/ 1000;
      int dbLng = lngIndex ~/ 1000;

      final dbKey = DBKey(cellZ, dbLat, dbLng);
      // 親ズームで pending な delta があれば先に flush。
      if (cellZ < 14 && _pendingParentDeltas.containsKey(dbKey)) {
        await _flushPendingForShard(dbKey);
      }
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
  ///
  /// インポート完了後に呼ばれた場合は、末尾で `resumeWrites()` も実行する
  /// （`closeAll()` で停止された書き込みを再開する）。
  Future<void> scanExistingDatabases() async {
    final dbPath = await _dbDirectoryPath;
    final dir = Directory(dbPath);
    if (!await dir.exists()) {
      resumeWrites();
      return;
    }

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
    resumeWrites();
  }

  /// 全ての開いているDBを閉じる。
  /// 同時に `pauseWrites()` を実行し、close 後の in-flight 書き込みが
  /// 空 DB を再作成してしまうレースを防ぐ。
  Future<void> closeAll() async {
    // ここで flush しないとメモリに残った親 delta が失われるが、
    // 呼び出し元（インポート / 全削除）は直後に DB を差し替えるので、
    // 古い delta を書き戻しても無意味。バッファごと破棄する。
    pauseWrites();
    for (var db in _openDatabases.values) {
      try {
        await db.close();
      } catch (_) {
        // 既に閉じている／壊れているケースは無視（cache をクリアできれば OK）。
      }
    }
    _openDatabases.clear();
    _openDbModes.clear();
    _shardCellCache.clear();
    _shardPrefetchInFlight.clear();
    _pendingParentDeltas.clear();
  }

  /// 記録済みデータを全て削除する。
  /// 呼び出し元は事前に描画と位置記録を停止しておくこと（MapViewModel.setBusy(true)）。
  Future<void> clearAllData() async {
    await closeAll();
    final dbPath = await _dbDirectoryPath;
    final dir = Directory(dbPath);
    if (!await dir.exists()) {
      resumeWrites();
      return;
    }
    final files = dir.listSync();
    for (final f in files) {
      if (f is File &&
          (f.path.endsWith('.db') ||
              f.path.endsWith('.sqlite') ||
              f.path.endsWith('.db-journal') ||
              f.path.endsWith('.sqlite-journal'))) {
        try {
          await f.delete();
          debugPrint('Cleared: ${p.basename(f.path)}');
        } catch (e) {
          debugPrint('Failed to clear ${p.basename(f.path)}: $e');
        }
      }
    }
    // 削除完了したので書き込みを再開（fresh state なので新規 DB が作られる）。
    resumeWrites();
  }

  /// 指定された時間範囲に含まれるセルを全DBから検索して取得 (Zoom 14 と仮定)
  ///
  /// パフォーマンス最適化:
  /// - shard 単位の query を `Future.wait` で並列実行
  /// - `openDB` のキャッシュを使うことで同一 shard への再オープンコストを回避
  ///   （従来は毎回 raw `openDatabase` → `close` していた）
  Future<List<Cell>> fetchCellsByTimeRange(int startTime, int endTime) async {
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

    // 対象 shard の DBKey 一覧を作る
    final List<DBKey> keys = [];
    for (var f in files) {
      if (f is! File) continue;
      final name = p.basename(f.path);
      final match = shardPattern.firstMatch(name);
      if (match == null) continue;
      final tx = int.tryParse(match.group(1) ?? '');
      final ty = int.tryParse(match.group(2) ?? '');
      if (tx == null || ty == null) continue;
      keys.add(DBKey(14, tx, ty));
    }

    // shard 毎の query を並列実行。sqflite は内部的に単一 worker で
    // シリアライズされるが、キュー化されるので await を fan-out させる方が
    // platform channel スループットを引き出せる。
    final results = await Future.wait(keys.map((key) async {
      try {
        final db = await openDB(key, readOnly: true);
        if (db == null) return const <Cell>[];
        // tm または p1 のいずれかが範囲に入るセルを対象にする
        final res = await db.query(
          'heatmap_table',
          where: '(tm >= ? AND tm <= ?) OR (p1 >= ? AND p1 <= ?)',
          whereArgs: [start, end, start, end],
        );
        return res.map(Cell.fromSqlite).toList(growable: false);
      } catch (e) {
        debugPrint('Error querying DB $key: $e');
        return const <Cell>[];
      }
    }));

    final all = results.expand((e) => e).toList();
    debugPrint('Total cells found in range: ${all.length}');
    return all;
  }

  /// 区間削除等のための削除処理。shard 単位で batch 化し、
  /// shard あたり open / transaction を 1 回に圧縮する。
  /// [targetCells] は Zoom 14 のセルリストと仮定
  Future<void> deleteCells(List<Cell> targetCells,
      {Function(int, int)? onProgress}) async {
    if (_writesPaused) return;
    if (targetCells.isEmpty) return;
    const int baseZ = 14;
    final int totalCount = targetCells.length;

    // shard キー -> 操作リスト（その shard 内で実行する増減）。
    // 値は (lat, lng, delta) で、delta < 0 の場合は減算（0 以下なら削除）、
    // forceDelete 用は 0 を入れて専用フラグで区別する。
    final Map<DBKey, List<(int, int, int, bool)>> opsByShard = {};

    for (final cell in targetCells) {
      // Zoom 14 自身は強制削除
      final z14Key = DBKey(baseZ, cell.lat ~/ 1000, cell.lng ~/ 1000);
      (opsByShard[z14Key] ??= []).add((cell.lat, cell.lng, 0, true));

      // 親セル (Zoom 3-13) は val を引く。
      // cell index は非負なので `>>` は floor 割り算と等価かつ高速。
      for (int z = 3; z < baseZ; z++) {
        final int shift = baseZ - z;
        final int parentLat = cell.lat >> shift;
        final int parentLng = cell.lng >> shift;
        final key = DBKey(z, parentLat ~/ 1000, parentLng ~/ 1000);
        (opsByShard[key] ??= []).add((parentLat, parentLng, -cell.val, false));
      }
    }

    int processedCells = 0;
    for (final entry in opsByShard.entries) {
      if (_writesPaused) return;
      // 親ズーム shard に pending delta があると、直後の減算計算が
      // DB 上の古い val を基準にしてしまう。先に flush して整合させる。
      if (entry.key.z < baseZ &&
          _pendingParentDeltas.containsKey(entry.key)) {
        await _flushPendingForShard(entry.key);
      }
      await _applyDeltaOpsForShard(entry.key, entry.value);
      // 進捗は shard 単位だが、見た目は cell 単位で進めたいので比例配分する。
      // 厳密な処理セル数は読まず、shard ごとに「全体 / shard数」分進める。
      processedCells += (totalCount / opsByShard.length).round();
      if (onProgress != null) {
        onProgress(processedCells.clamp(0, totalCount), totalCount);
      }
    }
    if (onProgress != null) {
      onProgress(totalCount, totalCount);
    }
  }

  /// 単一 shard 内で delta 操作（増減・強制削除）をまとめて batch 実行する。
  ///
  /// 既存値を 1 回の `SELECT` で取得し、各操作を計算した上で
  /// `INSERT` / `UPDATE` / `DELETE` を `Batch` に積んで `commit(noResult:true)` する。
  /// これによりプラットフォームチャネル往復が cell 数 × N から shard あたり 2 回
  /// (SELECT + COMMIT) に圧縮され、main thread への負荷とロック競合が大幅に下がる。
  Future<({int newCells, int existingCells})> _applyDeltaOpsForShard(
      DBKey key, List<(int, int, int, bool)> ops) async {
    if (_writesPaused) return (newCells: 0, existingCells: 0);
    if (ops.isEmpty) return (newCells: 0, existingCells: 0);

    final db = await openDB(key, readOnly: false);
    if (db == null) return (newCells: 0, existingCells: 0);

    // 同じ (lat, lng) に対する複数操作を集約する。
    final Map<(int, int), int> deltaByCell = {};
    final Set<(int, int)> forceDelete = {};
    for (final (lat, lng, delta, force) in ops) {
      final k = (lat, lng);
      if (force) {
        forceDelete.add(k);
      } else {
        deltaByCell[k] = (deltaByCell[k] ?? 0) + delta;
      }
    }

    // 既存値をまとめて SELECT。shard あたり最大数千行のはずなので
    // IN 句より lat/lng range で先読みするのが速いが、安全側として個別 SELECT を
    // 1 回の query にまとめる。
    final cellKeys = <(int, int)>{...deltaByCell.keys, ...forceDelete};
    if (cellKeys.isEmpty) return (newCells: 0, existingCells: 0);

    // 範囲取得（shard 内の関連セルだけを 1 クエリで取得）。
    final lats = cellKeys.map((k) => k.$1);
    final lngs = cellKeys.map((k) => k.$2);
    final int minLat = lats.reduce(min);
    final int maxLat = lats.reduce(max);
    final int minLng = lngs.reduce(min);
    final int maxLng = lngs.reduce(max);

    Map<(int, int), Map<String, Object?>> existing = {};
    try {
      final rows = await db.query(
        'heatmap_table',
        columns: ['lat', 'lng', 'val', 'p1'],
        where: 'lat >= ? AND lat <= ? AND lng >= ? AND lng <= ?',
        whereArgs: [minLat, maxLat, minLng, maxLng],
      );
      for (final r in rows) {
        final l = r['lat'] as int;
        final g = r['lng'] as int;
        if (cellKeys.contains((l, g))) {
          existing[(l, g)] = r;
        }
      }
    } catch (e) {
      _logDbError('shard delta select', key, e);
      return (newCells: 0, existingCells: 0);
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    // z=14 で recordVisitedCells14 から呼ばれたケース用に、
    // 「新規セル」と「既存セル」をカウントする。実際に batch へ積む条件と
    // 完全に合わせる（delta>0 かつ実際に insert または update されるものだけ）。
    int newCount = 0;
    int existingCount = 0;
    // 大量削除を 1 本の SQL にまとめるための収集リスト。
    // 個別 `batch.delete` は N 発のステートメントになりコミット時間が線形に伸びるため、
    // `(lat,lng) IN ((?,?), (?,?), ...)` を chunk して `rawDelete` で流す。
    final List<(int, int)> toDelete = [];
    for (final cellKey in cellKeys) {
      final (lat, lng) = cellKey;
      if (forceDelete.contains(cellKey)) {
        toDelete.add(cellKey);
        continue;
      }
      final delta = deltaByCell[cellKey] ?? 0;
      if (delta == 0) continue;

      final row = existing[cellKey];
      if (row == null) {
        if (delta > 0) {
          batch.insert('heatmap_table', {
            'lat': lat,
            'lng': lng,
            'val': delta,
            'tm': now,
            'p1': now,
          });
          newCount++;
        }
        // 既存無し & delta < 0 は no-op
      } else {
        final int currentVal = row['val'] as int;
        final int next = currentVal + delta;
        if (next <= 0) {
          toDelete.add(cellKey);
        } else {
          final int? p1 = row['p1'] as int?;
          final Map<String, Object?> upd = {'val': next, 'tm': now};
          if (delta > 0 && (p1 == null || p1 <= 0)) {
            upd['p1'] = now;
          }
          batch.update('heatmap_table', upd,
              where: 'lat = ? AND lng = ?', whereArgs: [lat, lng]);
          if (delta > 0) existingCount++;
        }
      }
    }

    try {
      // まず insert / update を一括コミット。
      await batch.commit(noResult: true);
      // 続いて削除を chunked 単一 SQL で流す。
      if (toDelete.isNotEmpty) {
        // SQLITE_LIMIT_VARIABLE_NUMBER=999 を想定し、1 組 = 2 パラメータなので
        // chunk 上限を 400 組 (= 800 パラメータ) としておく。
        const int chunkSize = 400;
        for (int i = 0; i < toDelete.length; i += chunkSize) {
          final end = (i + chunkSize < toDelete.length)
              ? i + chunkSize
              : toDelete.length;
          final chunk = toDelete.sublist(i, end);
          final placeholders =
              List.filled(chunk.length, '(?,?)').join(',');
          final args = <int>[];
          for (final (l, g) in chunk) {
            args.add(l);
            args.add(g);
          }
          await db.rawDelete(
            'DELETE FROM heatmap_table WHERE (lat,lng) IN ($placeholders)',
            args,
          );
        }
      }
    } catch (e) {
      _logDbError('shard batch commit', key, e);
      return (newCells: 0, existingCells: 0);
    }

    // この shard のキャッシュは丸ごと破棄。次回 prefetch / fetch で再構築。
    _shardCellCache.remove(key);
    return (newCells: newCount, existingCells: existingCount);
  }

  /// 移動に伴い通過した Zoom14 セル（重複なし）を記録する。
  ///
  /// **書き込み戦略**:
  /// - z=14: 即時書き込み（タップ・エクスポート・タイル描画の全てで真実を提供）
  /// - z=3..13: `_pendingParentDeltas` にメモリ加算し、
  ///   その shard が読まれる直前（fetchCells / prefetchShards / getCell）に
  ///   まとめて flush する write-behind 方式。
  ///
  /// これにより 1 GPS tick あたりの main-thread プラットフォームチャネル RTT が
  /// 「24 → 2 （1/12）」に圧縮され、GPS を止めずに指操作のレスポンスを守れる。
  /// この記録によって「新規」だったセル数と「既存」だったセル数を返す。
  /// area3.db の日次履歴（cell1=新規、cell2=既存、area1/area2=各×315m2）更新に使う。
  Future<({int newCells, int existingCells})> recordVisitedCells14(
      Set<(int, int)> cellIndices) async {
    if (_writesPaused) return (newCells: 0, existingCells: 0);
    if (cellIndices.isEmpty) return (newCells: 0, existingCells: 0);
    const int baseZ = 14;

    // --- 1. z=14 の shard 単位 ops を集約してインライン書き込み ---
    final Map<DBKey, List<(int, int, int, bool)>> z14Ops = {};
    for (final (lat, lng) in cellIndices) {
      final z14Key = DBKey(baseZ, lat ~/ 1000, lng ~/ 1000);
      (z14Ops[z14Key] ??= []).add((lat, lng, 1, false));
    }
    int newCells = 0;
    int existingCells = 0;
    for (final entry in z14Ops.entries) {
      if (_writesPaused) break;
      final counts = await _applyDeltaOpsForShard(entry.key, entry.value);
      newCells += counts.newCells;
      existingCells += counts.existingCells;
    }

    // --- 2. z=3..13 の親セル delta はメモリに蓄積 ---
    // cell index は非負なので `>>` は floor 割り算と等価かつ高速。
    for (final (lat, lng) in cellIndices) {
      for (int z = 3; z < baseZ; z++) {
        final int shift = baseZ - z;
        final int parentLat = lat >> shift;
        final int parentLng = lng >> shift;
        final key = DBKey(z, parentLat ~/ 1000, parentLng ~/ 1000);
        final deltas = _pendingParentDeltas[key] ??= <(int, int), int>{};
        final cellKey = (parentLat, parentLng);
        deltas[cellKey] = (deltas[cellKey] ?? 0) + 1;
      }
    }

    return (newCells: newCells, existingCells: existingCells);
  }

  /// 特定 shard に蓄積した親セル delta を DB に flush する。
  /// 該当エントリがなければ no-op。
  Future<void> _flushPendingForShard(DBKey key) async {
    if (_writesPaused) return;
    final deltas = _pendingParentDeltas.remove(key);
    if (deltas == null || deltas.isEmpty) return;
    final ops = <(int, int, int, bool)>[
      for (final entry in deltas.entries)
        (entry.key.$1, entry.key.$2, entry.value, false),
    ];
    await _applyDeltaOpsForShard(key, ops);
  }

  /// 蓄積した全親セル delta を flush する。アプリ終了時やバックグラウンド遷移時に
  /// 呼ぶのが安全。
  Future<void> flushAllPendingParents() async {
    if (_writesPaused) return;
    if (_pendingParentDeltas.isEmpty) return;
    final keys = _pendingParentDeltas.keys.toList();
    for (final key in keys) {
      if (_writesPaused) return;
      await _flushPendingForShard(key);
    }
  }

  /// 共通エラーロガー。インポート中の race で発生する SQLITE_READONLY_DBMOVED は
  /// ユーザーには無関係なノイズ（しかも頻発するとログ I/O で main thread を
  /// 飽和させる）なので、debugPrint を出さずに静かに drop する。
  void _logDbError(String where, DBKey key, Object e) {
    final msg = e.toString();
    if (msg.contains('SQLITE_READONLY_DBMOVED') ||
        msg.contains('readonly database') ||
        msg.contains('database is locked')) {
      // インポート中／close 直後のレース由来。pause を入れているので
      // ほぼ起きないはずだが、保険として静かに無視する。
      return;
    }
    debugPrint('DB error at $where ($key): $e');
  }

  /// z=14 の全 shard を走査し、
  /// 「重複なしセル数（COUNT(*)）」と「重複ありセル数（SUM(val)）」を返す。
  ///
  /// - 重複なし: 各 z=14 セルが DB に 1 行として存在するので COUNT(*)。
  /// - 重複あり: `val` は同一セルを通過した回数なので、その総和が延べ回数。
  ///
  /// 全 shard を開くのはコストがあるため、HUD 表示など頻繁には呼ばず、
  /// ViewModel 側で適度にデバウンスして呼ぶこと。
  Future<({int uniqueCells, int totalVisits})> getZ14TotalStats() async {
    final dbDirPath = await _dbDirectoryPath;
    final dir = Directory(dbDirPath);
    if (!await dir.exists()) {
      return (uniqueCells: 0, totalVisits: 0);
    }
    int unique = 0;
    int total = 0;
    final re = RegExp(r'^hm_14_(-?\d+)_(-?\d+)\.db$');
    final entities = dir.listSync();
    for (final f in entities) {
      if (f is! File) continue;
      final name = p.basename(f.path);
      final m = re.firstMatch(name);
      if (m == null) continue;
      final latIdx = int.tryParse(m.group(1) ?? '');
      final lngIdx = int.tryParse(m.group(2) ?? '');
      if (latIdx == null || lngIdx == null) continue;
      final key = DBKey(14, latIdx, lngIdx);
      final db = await openDB(key, readOnly: true);
      if (db == null) continue;
      try {
        final rows = await db.rawQuery(
            'SELECT COUNT(*) AS c, COALESCE(SUM(val), 0) AS s FROM heatmap_table');
        if (rows.isNotEmpty) {
          final r = rows.first;
          unique += (r['c'] as int?) ?? 0;
          total += (r['s'] as int?) ?? 0;
        }
      } catch (e) {
        _logDbError('z14 stats', key, e);
      }
    }
    return (uniqueCells: unique, totalVisits: total);
  }

  /// z=14 の既存データから z=3..13 の親ズームセルを全て再構築する。
  ///
  /// ロジック:
  /// 1. `hm_3_*.db` … `hm_13_*.db` を全削除（派生データなので捨てて良い）。
  /// 2. 各 z=14 shard を順に走査し、その shard 内の `(lat, lng, val)` を
  ///    `>>` 演算で親インデックスへ丸めつつ、メモリ上の delta マップに
  ///    `val` ぶん加算する（各 z ごと）。
  /// 3. 走査が進むたびに、もう二度と触らない親 shard の delta を逐次 flush して
  ///    メモリ消費を抑える。最後に `flushAllPendingParents()` で残りを書き出し。
  ///
  /// 大量データでも安全に走るよう、**shard 単位でストリーム処理** する。
  /// 呼び出し中は `pauseWrites()` → `resumeWrites()` で GPS 記録の並行書き込みを
  /// 抑止する（そうしないと z=14 の新規記録が走査途中で混ざる）。
  ///
  /// [onProgress] は `(processedShards, totalShards)` で進捗を通知する。
  Future<void> rebuildParentZoomsFromZ14({
    void Function(int processed, int total)? onProgress,
  }) async {
    final dbDirPath = await _dbDirectoryPath;
    final dir = Directory(dbDirPath);
    if (!await dir.exists()) return;

    // --- 書き込みを停止し、既存の親 shard を全削除 ---
    pauseWrites();
    try {
      // 開いている親 DB を閉じる（削除前に）。
      final toClose = <DBKey>[];
      for (final k in _openDatabases.keys) {
        if (k.z >= 3 && k.z <= 13) toClose.add(k);
      }
      for (final k in toClose) {
        try {
          await _openDatabases[k]?.close();
        } catch (_) {}
        _openDatabases.remove(k);
        _openDbModes.remove(k);
        _shardCellCache.remove(k);
      }
      _pendingParentDeltas.clear();

      // 親 shard ファイル群を削除。
      final parentRe = RegExp(r'^hm_([3-9]|1[0-3])_.*\.(db|sqlite)$');
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        if (parentRe.hasMatch(p.basename(f.path))) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }

      // --- z=14 shard を走査して親 delta を再生成 ---
      final z14Re = RegExp(r'^hm_14_(-?\d+)_(-?\d+)\.(db|sqlite)$');
      final z14Files = <File>[];
      for (final f in dir.listSync()) {
        if (f is File && z14Re.hasMatch(p.basename(f.path))) {
          z14Files.add(f);
        }
      }
      final int total = z14Files.length;
      int processed = 0;
      onProgress?.call(processed, total);

      for (final f in z14Files) {
        final m = z14Re.firstMatch(p.basename(f.path))!;
        final latIdx = int.parse(m.group(1)!);
        final lngIdx = int.parse(m.group(2)!);
        final key = DBKey(14, latIdx, lngIdx);

        // z=14 shard を読み取り専用で一時的に開く（_writesPaused でも readOnly は許可）。
        final db = await openDatabase(f.path, readOnly: true);
        List<Map<String, Object?>> rows = const [];
        try {
          rows = await db.query('heatmap_table',
              columns: ['lat', 'lng', 'val']);
        } catch (e) {
          _logDbError('rebuild read', key, e);
        } finally {
          try {
            await db.close();
          } catch (_) {}
        }

        // 読み取った全セルについて z=3..13 の delta を加算。
        for (final row in rows) {
          final int lat = row['lat'] as int;
          final int lng = row['lng'] as int;
          final int val = (row['val'] as int?) ?? 0;
          if (val <= 0) continue;
          for (int z = 3; z < 14; z++) {
            final int shift = 14 - z;
            final int parentLat = lat >> shift;
            final int parentLng = lng >> shift;
            final pKey = DBKey(z, parentLat ~/ 1000, parentLng ~/ 1000);
            final deltas = _pendingParentDeltas[pKey] ??=
                <(int, int), int>{};
            final cKey = (parentLat, parentLng);
            deltas[cKey] = (deltas[cKey] ?? 0) + val;
          }
        }

        processed++;
        onProgress?.call(processed, total);
      }
    } finally {
      // 書き込み再開 → pending delta を実 DB に書き出す。
      resumeWrites();
      // 親 delta の flush は直接 _applyDeltaOpsForShard を使うため、
      // _writesPaused=false でないと動かない。
      await flushAllPendingParents();
    }
  }

  /// area3.db の `area_table` にその日の統計を加算する。
  ///
  /// - ファイルが無ければスキーマ付きで新規作成。
  /// - その日の行が無ければ `INSERT`、あれば `UPDATE` で cell1/cell2/area1/area2 を加算。
  /// - `date` は Android 互換のため `yyyyMMdd` の整数（例 20241129）。
  ///
  /// 呼び出しコストを抑えるため、GPS 1 tick あたり 1 回（差分セル記録直後）だけ呼ぶ。
  Future<void> recordDailyArea({
    required int newCells,
    required int existingCells,
    DateTime? now,
  }) async {
    if (_writesPaused) return;
    if (newCells == 0 && existingCells == 0) return;

    final dt = now ?? DateTime.now();
    final int dateKey = dt.year * 10000 + dt.month * 100 + dt.day;
    final double area1Delta = newCells * 314.8553;
    final double area2Delta = existingCells * 314.8553;

    final dir = await _dbDirectoryPath;
    final path = p.join(dir, 'area3.db');
    Database? db;
    try {
      db = await openDatabase(
        path,
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE area_table (
              date INTEGER PRIMARY KEY,
              cell1 INTEGER,
              cell2 INTEGER,
              area1 REAL,
              area2 REAL,
              event1 INTEGER,
              event2 INTEGER,
              event3 INTEGER,
              event4 INTEGER
            )
          ''');
        },
      );
      final existing = await db.query('area_table',
          where: 'date = ?', whereArgs: [dateKey], limit: 1);
      if (existing.isEmpty) {
        await db.insert('area_table', {
          'date': dateKey,
          'cell1': newCells,
          'cell2': existingCells,
          'area1': area1Delta,
          'area2': area2Delta,
          'event1': 0,
          'event2': 0,
          'event3': 0,
          'event4': 0,
        });
      } else {
        final row = existing.first;
        final int cell1 = (row['cell1'] as int?) ?? 0;
        final int cell2 = (row['cell2'] as int?) ?? 0;
        final double area1 = (row['area1'] as num?)?.toDouble() ?? 0;
        final double area2 = (row['area2'] as num?)?.toDouble() ?? 0;
        await db.update(
          'area_table',
          {
            'cell1': cell1 + newCells,
            'cell2': cell2 + existingCells,
            'area1': area1 + area1Delta,
            'area2': area2 + area2Delta,
          },
          where: 'date = ?',
          whereArgs: [dateKey],
        );
      }
    } catch (e) {
      debugPrint('area3.db recordDailyArea error: $e');
    } finally {
      await db?.close();
    }
  }

  /// title.db の `title_table` にその日付のタイトルを設定する（空文字は削除扱い）。
  ///
  /// - ファイルが無ければスキーマ付きで新規作成。
  /// - 既にその日付の行があれば UPDATE、無ければ INSERT。
  /// - `title` が空文字なら行を DELETE（未設定に戻す）。
  Future<void> setDailyTitle({
    required int dateKey,
    required String title,
  }) async {
    final dir = await _dbDirectoryPath;
    final path = p.join(dir, 'title.db');
    Database? db;
    try {
      db = await openDatabase(
        path,
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE title_table (
              date INTEGER PRIMARY KEY,
              title TEXT
            )
          ''');
        },
      );
      final trimmed = title.trim();
      if (trimmed.isEmpty) {
        await db
            .delete('title_table', where: 'date = ?', whereArgs: [dateKey]);
      } else {
        // INSERT OR REPLACE で upsert。
        await db.rawInsert(
          'INSERT OR REPLACE INTO title_table (date, title) VALUES (?, ?)',
          [dateKey, trimmed],
        );
      }
    } catch (e) {
      debugPrint('title.db setDailyTitle error: $e');
      rethrow;
    } finally {
      await db?.close();
    }
  }
}

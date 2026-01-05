import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/cell.dart';
import '../models/db_key.dart';

/// SQLiteデータベースへのアクセスを担当するリポジトリ
class DatabaseRepository {
  // シングルトン化 (アプリ全体でDB接続を管理するため)
  static final DatabaseRepository _instance = DatabaseRepository._internal();
  factory DatabaseRepository() => _instance;
  DatabaseRepository._internal();

  // DBインスタンスのキャッシュ (開いたDBを再利用)
  final Map<DBKey, Database> _openDatabases = {};

  /// データベースディレクトリのパスを取得
  Future<String> get _dbDirectoryPath async {
    return await getDatabasesPath();
  }

  /// 特定のキーに対応するデータベースを開く
  Future<Database?> openDB(DBKey key, {bool readOnly = true}) async {
    final dbDir = await _dbDirectoryPath;
    final path = p.join(dbDir, key.toFileName());

    // キャッシュチェック
    if (_openDatabases.containsKey(key)) {
      final db = _openDatabases[key]!;
      if (db.isOpen) return db;
      _openDatabases.remove(key); // 閉じていたら削除
    }

    final file = File(path);
    if (!await file.exists()) {
      if (readOnly) {
        // 読み取り専用でファイルが無ければnullを返す
        return null;
      }
      // 書き込みモードなら新規作成されるが、ここでは単純化のため、
      // 既存DBへの書き込みとみなし、存在しない場合のハンドリングは呼び出し元に任せる動きも可能。
      // ただし、sqfliteのopenDatabaseはファイルが無ければ作成する。
    }

    try {
      final db = await openDatabase(
        path,
        readOnly: readOnly,
        // 読み取り専用時はバージョンチェックを行わせない (書き込みが発生してエラーになるのを防ぐ)
        version: readOnly ? null : 1,
        onCreate: readOnly
            ? null
            : (db, version) async {
                // 新規作成時のスキーマ定義 (必要に応じて)
                await db.execute(
                    'CREATE TABLE IF NOT EXISTS heatmap_table (lat INTEGER, lng INTEGER, val INTEGER, tm INTEGER, p1 INTEGER, PRIMARY KEY (lat, lng))');
                await db.execute(
                    'CREATE INDEX IF NOT EXISTS idx_lat_lng ON heatmap_table (lat, lng)');
              },
      );
      _openDatabases[key] = db;
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

      // 5. 各DBからデータを取得
      for (int dblat = dbLatStart; dblat <= dbLatEnd; dblat++) {
        for (int dblng = dbLngStart; dblng <= dbLngEnd; dblng++) {
          final dbKey = DBKey(cellZ, dblat, dblng);
          final db = await openDB(dbKey, readOnly: true);

          if (db != null) {
            await _loadCellsFromDb(db, cells, s, n, w, e);
          }
        }
      }
    } catch (e) {
      debugPrint('Error in fetchCells: $e');
    }

    return cells;
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

  /// DBから範囲内のセルを読み込む
  Future<void> _loadCellsFromDb(
      Database db, Set<Cell> cells, int s, int n, int w, int e) async {
    try {
      // 範囲検索
      final List<Map<String, dynamic>> res = await db.query(
        'heatmap_table',
        where: 'lat >= ? AND lat <= ? AND lng >= ? AND lng <= ?',
        whereArgs: [s, n, w, e],
      );

      for (final row in res) {
        cells.add(Cell.fromSqlite(row));
      }
    } catch (e) {
      debugPrint('DB query error: $e');
    }
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
  Future<void> scanExistingDatabases() async {
    final dbPath = await _dbDirectoryPath;
    final dir = Directory(dbPath);
    if (!await dir.exists()) return;

    final files = dir.listSync();
    debugPrint('--- DatabaseRepository: Scan Existing Files ---');
    for (var f in files) {
      if (f is File && (f.path.endsWith('.db') || f.path.endsWith('.sqlite'))) {
        debugPrint('Found DB: ${p.basename(f.path)} Size: ${await f.length()}');
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
  }
}

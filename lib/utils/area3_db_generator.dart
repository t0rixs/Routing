import 'dart:io';
import 'package:sqflite/sqflite.dart';

/// area3.db（エリア・イベントデータベース）生成ユーティリティ
///
/// Android版マッピングアプリとの互換性のため、
/// iOS元データをエクスポートする際に使用します。
///
/// 注意: iOS版では ue3.db という名前ですが、Android版は area3.db を期待します。
class Area3DbGenerator {
  /// 空の area3.db ファイルを生成
  ///
  /// Android版マッピングアプリが期待する構造：
  /// - android_metadata テーブル（ロケール情報）
  /// - area_table テーブル（エリア・イベント情報、空）
  ///
  /// [outputPath]: 出力先のパス（ファイル名含む）
  /// Returns: 生成されたファイルのバイトデータ
  static Future<List<int>> generateEmptyArea3Db(String outputPath) async {
    // 一時的にデータベースを作成
    final db = await openDatabase(
      outputPath,
      version: 1,
      onCreate: (db, version) async {
        // area_table テーブル作成（Android版のスキーマ）
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

    // android_metadata は sqflite が自動作成するので、ロケールを設定
    try {
      await db.execute(
          'INSERT INTO android_metadata (locale) VALUES (?)', ['ja_JP']);
    } catch (e) {
      // 既に存在する場合は更新
      await db.execute('UPDATE android_metadata SET locale = ?', ['ja_JP']);
    }

    // データベースを閉じる
    await db.close();

    // ファイルを読み込んで返す
    final file = File(outputPath);
    final bytes = await file.readAsBytes();

    return bytes;
  }

  /// 空の ue3.db ファイルを生成（Android版互換用、中身は空）
  static Future<List<int>> generateEmptyUe3Db(String outputPath) async {
    final db = await openDatabase(
      outputPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE userevent3_table (
            _id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_account_id TEXT,
            ue3 BLOB,
            timestamp INTEGER
          )
        ''');
      },
    );

    try {
      await db.execute(
          'INSERT INTO android_metadata (locale) VALUES (?)', ['ja_JP']);
    } catch (e) {
      await db.execute('UPDATE android_metadata SET locale = ?', ['ja_JP']);
    }

    await db.close();
    return File(outputPath).readAsBytes();
  }

  /// area3.db が必要かチェック
  static bool needsArea3Db(List<String> fileNames) {
    return !fileNames.contains('area3.db');
  }

  /// ue3.db が必要かチェック（空のDBが必要な場合）
  static bool needsUe3Db(List<String> fileNames) {
    return !fileNames.contains('ue3.db');
  }

  /// google_app_measurement_local.db が必要かチェック
  ///
  /// [fileNames]: アーカイブ内のファイル名リスト
  /// Returns: google_app_measurement_local.db の生成が必要なら true
  static bool needsGoogleMeasurementDb(List<String> fileNames) {
    return !fileNames.contains('google_app_measurement_local.db');
  }

  /// 空の google_app_measurement_local.db を生成
  ///
  /// Google Analytics用のデータベース（通常は空）
  ///
  /// [outputPath]: 出力先のパス（ファイル名含む）
  /// Returns: 生成されたファイルのバイトデータ
  static Future<List<int>> generateEmptyGoogleMeasurementDb(
      String outputPath) async {
    // 最小限のSQLiteデータベースを作成
    final db = await openDatabase(
      outputPath,
      version: 1,
      onCreate: (db, version) async {
        // 空のデータベース（テーブルなし）
        // android_metadata は sqflite が自動作成
      },
    );

    // ロケール設定
    try {
      await db.execute(
          'INSERT INTO android_metadata (locale) VALUES (?)', ['ja_JP']);
    } catch (e) {
      await db.execute('UPDATE android_metadata SET locale = ?', ['ja_JP']);
    }

    await db.close();

    final file = File(outputPath);
    final bytes = await file.readAsBytes();

    return bytes;
  }
}

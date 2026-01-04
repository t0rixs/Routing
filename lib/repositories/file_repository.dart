import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// ファイル操作 (.mappingファイルのインポート・エクスポート) を担当するリポジトリ
class FileRepository {
  /// XOR暗号化キー
  static const int _xorKey = 0x55;

  /// XOR暗号化/復号化処理
  static List<int> _xorProcess(List<int> bytes) {
    // Uint8Listに変換して高速化
    final data = Uint8List.fromList(bytes);
    for (int i = 0; i < data.length; i++) {
      data[i] ^= _xorKey;
    }
    return data;
  }

  /// .mappingファイルをインポートする
  /// [filePath]: 選択されたファイルのパス
  /// [dbBasePath]: アプリのデータベースディレクトリパス
  Future<void> importMappingFile(String filePath, String dbBasePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File not found: $filePath');
    }

    // 0. 既存データの削除 (Clean Install)
    final dbDir = Directory(dbBasePath);
    if (await dbDir.exists()) {
      final files = dbDir.listSync();
      for (final f in files) {
        if (f is File &&
            (f.path.endsWith('.db') || f.path.endsWith('.sqlite'))) {
          try {
            await f.delete();
            debugPrint('Deleted old DB: ${p.basename(f.path)}');
          } catch (e) {
            debugPrint('Failed to delete old DB: $e');
          }
        }
      }
    }

    // 1. .mapping (ZIP) を読み込む
    debugPrint('Opening mapping file: $filePath');
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 2. 中身を展開
    bool backupFound = false;
    for (final entity in archive) {
      debugPrint('Entry in mapping: ${entity.name}');
      if (entity.isFile) {
        // ZIP内のパスが含まれていても検知できるように endsWith または basename で判定
        if (entity.name.endsWith('myalltracks.backup')) {
          backupFound = true;
          debugPrint('Found backup file: ${entity.name}. Restoring...');
          await _restoreBackup(entity.content as List<int>, dbBasePath);
        } else if (p.extension(entity.name) == '.jpg') {
          // 画像ファイル等の処理
          // 必要ならば documents/imgs 等へ保存
        }
      }
    }
    if (!backupFound) {
      debugPrint('Warning: myalltracks.backup not found in mapping file.');
    }
  }

  /// 内部の .backup (ZIP) を展開し、DBファイルを復元する
  /// **ここで自動リネームロジックを実行する**
  Future<void> _restoreBackup(List<int> backupBytes, String dbBasePath) async {
    debugPrint('Restoring myalltracks.backup... Bytes: ${backupBytes.length}');

    // ヘッダー確認 (ファイル形式特定用)
    if (backupBytes.isNotEmpty) {
      var header = backupBytes.take(16).toList();
      final headerHex =
          header.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
      final headerStr =
          String.fromCharCodes(header.map((e) => e >= 32 && e <= 126 ? e : 46));
      debugPrint('Backup Header: [Hex] $headerHex  [Ascii] $headerStr');

      if (header.length >= 4) {
        // Custom Header: MyAllTracksBackup...
        // 4D 79 41 6C (MyAl)
        if (header[0] == 0x4D &&
            header[1] == 0x79 &&
            header[2] == 0x41 &&
            header[3] == 0x6C) {
          debugPrint('Type: Custom "MyAllTracksBackup" header detected.');

          // 有効なデータ(ZIP or SQLite)の開始位置を探す
          // 最初の2KBくらいをスキャン
          int startOffset = -1;
          final maxScan =
              (backupBytes.length < 2048) ? backupBytes.length : 2048;

          for (int i = 0; i < maxScan - 4; i++) {
            // ZIP (PK\x03\x04) -> 50 4B 03 04
            if (backupBytes[i] == 0x50 &&
                backupBytes[i + 1] == 0x4B &&
                backupBytes[i + 2] == 0x03 &&
                backupBytes[i + 3] == 0x04) {
              startOffset = i;
              debugPrint('Found ZIP signature at offset $i');
              break;
            }
            // XORed ZIP -> 05 1E 56 51
            if (backupBytes[i] == 0x05 &&
                backupBytes[i + 1] == 0x1E &&
                backupBytes[i + 2] == 0x56 &&
                backupBytes[i + 3] == 0x51) {
              startOffset = i;
              debugPrint('Found XORed ZIP signature at offset $i');
              break;
            }
            // SQLite -> 53 51 4C 69
            if (backupBytes[i] == 0x53 &&
                backupBytes[i + 1] == 0x51 &&
                backupBytes[i + 2] == 0x4C &&
                backupBytes[i + 3] == 0x69) {
              startOffset = i;
              debugPrint('Found SQLite signature at offset $i');
              break;
            }
            // XORed SQLite -> 06 04 19 3C
            if (backupBytes[i] == 0x06 &&
                backupBytes[i + 1] == 0x04 &&
                backupBytes[i + 2] == 0x19 &&
                backupBytes[i + 3] == 0x3C) {
              startOffset = i;
              debugPrint('Found XORed SQLite signature at offset $i');
              break;
            }
          }

          if (startOffset != -1) {
            debugPrint('Stripping custom header ($startOffset bytes)...');
            backupBytes = backupBytes.sublist(startOffset);
            // 再度ヘッダー情報を更新して後続のif文で引っかかるようにする
            header = backupBytes.take(16).toList();
          } else {
            debugPrint(
                'WARNING: Custom header found but no valid payload signature detected in first $maxScan bytes.');
          }
        }

        // ZIP (PK\x03\x04) -> 0x50 0x4B 0x03 0x04
        if (header[0] == 0x50 &&
            header[1] == 0x4B &&
            header[2] == 0x03 &&
            header[3] == 0x04) {
          debugPrint('Type: Standard ZIP');
        }
        // XORed ZIP (PK.. ^ 0x55) -> 0x05 0x1E 0x56 0x51
        else if (header[0] == 0x05 &&
            header[1] == 0x1E &&
            header[2] == 0x56 &&
            header[3] == 0x51) {
          debugPrint('Type: XORed ZIP. Decrypting...');
          backupBytes = _xorProcess(backupBytes);
        }
        // SQLite (SQLite format 3) -> 0x53 0x51 0x4C 0x69
        else if (header[0] == 0x53 &&
            header[1] == 0x51 &&
            header[2] == 0x4C &&
            header[3] == 0x69) {
          debugPrint('Type: Standard SQLite (Not ZIP). Treating as single DB.');
          await _restoreSingleDbFile(
              backupBytes, 'restored_single.db', dbBasePath);
          return;
        }
        // XORed SQLite -> 0x53^0x55=06, 0x51^0x55=04, 0x4C^0x55=19, 0x69^0x55=3C => 06 04 19 3C
        else if (header[0] == 0x06 &&
            header[1] == 0x04 &&
            header[2] == 0x19 &&
            header[3] == 0x3C) {
          debugPrint(
              'Type: XORed SQLite (Not ZIP). Decrypting and treating as single DB.');
          backupBytes = _xorProcess(backupBytes);
          await _restoreSingleDbFile(
              backupBytes, 'restored_single.db', dbBasePath);
          return;
        } else {
          debugPrint('Type: Unknown. Attempting ZIP decode anyway.');
        }
      }
    }

    // バックアップアーカイブのデコードを試みる
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(backupBytes);
      debugPrint('Backup archive decoded. Entries: ${archive.length}');
      if (archive.isEmpty) {
        debugPrint(
            'ERROR: ZIP archive is empty or invalid. Attempting to treat as single DB anyway (fallback).');
        // ヘッダーチェックで引っかからなくても、中身があるならDBとして試す価値あり？
        // いや、ZIPとして空ならそれはZIPとして認識されているがEOCDレコード等がおかしい場合がある。
        // ここではあえてsingle DBとしてリトライしてみる
        // await _restoreSingleDbFile(backupBytes, 'restored_fallback.db', dbBasePath);
        // return;
        return;
      }
    } catch (e) {
      debugPrint(
          'Error decoding backup archive: $e. Treating as potential single DB file explicitly.');
      // ZIPデコードエラー -> 単一ファイルの可能性が高い
      await _restoreSingleDbFile(
          backupBytes, 'restored_single_err.db', dbBasePath);
      return;
    }

    for (var file in archive) {
      // Force distinct log prefix to avoid dropping
      print('*** Backup Entry: ${file.name} (Size: ${file.size})');

      if (file.isFile) {
        final filename = file.name.toLowerCase();

        // .db または .sqlite ファイルを対象とする (大文字小文字無視)
        if (filename.endsWith('.db') || filename.endsWith('.sqlite')) {
          print('*** Processing DB file: ${file.name}');
          final encryptedBytes = file.content as List<int>;
          final decryptedBytes = _xorProcess(encryptedBytes);

          // SQLiteヘッダーチェック ("SQLite format 3" = 53 51 4c 69 74 65 20 66 6f 72 6d 61 74 20 33 00)
          String header = '';
          if (decryptedBytes.length > 16) {
            header = String.fromCharCodes(decryptedBytes.sublist(0, 16));
          }
          print('*** Header check for ${file.name}: $header');

          if (!header.startsWith('SQLite format 3')) {
            print(
                '*** WARNING: Invalid SQLite header for ${file.name}. Decryption might be wrong or file is not encrypted.');
            // 試しにそのまま(復号せず)保存してみる分岐も考えられるが、まずはログ確認
          }

          // ** 変更点: ファイル名からZoomを取得し、-2して保存する **
          String originalName = p.basename(file.name);
          String saveName = originalName;

          // 正規表現でファイル名をパース: hm_16_643_1601.db -> Group1: 16, Group2: 643_1601
          final regex = RegExp(r'^hm_(\d+)_(\d+_\d+)(?:\.db|\.sqlite)$',
              caseSensitive: false);
          final match = regex.firstMatch(originalName);

          if (match != null) {
            try {
              final int originalZoom = int.parse(match.group(1)!);
              final String coordsPart = match.group(2)!;

              // Zoom値を -2 する (最小値は 0 とする)
              int newZoom = originalZoom - 2;
              if (newZoom < 0) newZoom = 0;

              saveName = 'hm_${newZoom}_${coordsPart}.db';
              debugPrint(
                  'Zoom adjusted: $originalName -> $saveName (Zoom $originalZoom -> $newZoom)');
            } catch (e) {
              debugPrint('Error parsing/adjusting zoom for $originalName: $e');
            }
          } else {
            // 拡張子正規化 (.sqlite -> .db) のみ行う
            if (originalName.toLowerCase().endsWith('.sqlite')) {
              saveName =
                  originalName.substring(0, originalName.length - 7) + '.db';
            }
          }

          final finalPath = p.join(dbBasePath, saveName);
          final finalFile = File(finalPath);

          if (await finalFile.exists()) {
            await finalFile.delete();
          }
          await finalFile.writeAsBytes(decryptedBytes);
          debugPrint('Restored: ${file.name} -> $saveName');
        } else {
          debugPrint('Skipped non-db file: $filename');
        }
      }
    }
  }

  /// 単一のDBファイルバイト列を復元処理に回す (ZIPでない場合用)
  Future<void> _restoreSingleDbFile(
      List<int> bytes, String filename, String dbBasePath) async {
    print('*** Processing Single DB file: $filename');

    // 単純に保存 (リネームロジック廃止)
    final finalPath = p.join(dbBasePath, filename);
    final finalFile = File(finalPath);

    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await finalFile.writeAsBytes(bytes);
    debugPrint('Restored Single DB: $filename');
  }
}

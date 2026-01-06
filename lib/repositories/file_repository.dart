import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import '../utils/journal_generator.dart';
import '../utils/area3_db_generator.dart';

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
  Future<void> importMappingFile(String filePath, String dbBasePath,
      {Function(int, int)? onProgress}) async {
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
          await _restoreBackup(
              entity.content as List<int>, dbBasePath, onProgress);
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
  Future<void> _restoreBackup(List<int> backupBytes, String dbBasePath,
      Function(int, int)? onProgress) async {
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

    int totalFiles = archive.length;
    int processedCount = 0;

    for (var file in archive) {
      processedCount++;
      if (onProgress != null) {
        onProgress(processedCount, totalFiles);
      }
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

  /// 現在のDBデータをエクスポートして .mapping ファイルを作成し、共有する
  /// Android版・iOS版両対応（同じ形式）
  /// [dbBasePath]: データベースディレクトリパス
  Future<void> exportMappingFile(String dbBasePath,
      {Function(int, int)? onProgress}) async {
    debugPrint('Exporting .mapping file from $dbBasePath');
    final dbDir = Directory(dbBasePath);
    if (!await dbDir.exists()) {
      debugPrint('No database directory found.');
      return;
    }

    // 1. 第一段階ZIP用のアーカイブ作成 (myalltracks.backup の中身)
    final innerArchive = Archive();
    final files = dbDir.listSync(recursive: false);
    final totalFiles = files.length;
    int processedCount = 0;
    int dbCount = 0;

    for (var entity in files) {
      processedCount++;
      if (onProgress != null) {
        onProgress(processedCount, totalFiles);
      }
      if (entity is! File) continue;

      final name = p.basename(entity.path);
      final lowerName = name.toLowerCase();

      // 対象: .db, .db-journal ファイル
      bool isTarget = false;
      if (lowerName.endsWith('.db') ||
          lowerName.endsWith('.db-journal') ||
          lowerName.endsWith('.sqlite') ||
          lowerName.endsWith('.sqlite-journal')) {
        isTarget = true;
      }

      if (isTarget) {
        String exportName = name;

        // hm_ ファイルの場合、Zoom +2 調整
        final regex = RegExp(
            r'^hm_(\d+)_(\d+_\d+)(?:\.db|\.sqlite)((?:-journal)?)$',
            caseSensitive: false);
        final match = regex.firstMatch(name);

        if (match != null) {
          try {
            final int currentZoom = int.parse(match.group(1)!);
            final String coordsPart = match.group(2)!;
            final String journalSuffix = match.group(3) ?? '';
            final int newZoom = currentZoom + 2;

            // 拡張子は .db に統一
            exportName = 'hm_${newZoom}_${coordsPart}.db$journalSuffix';
          } catch (e) {
            debugPrint('Error adjusting zoom for export $name: $e');
          }
        } else {
          // .sqlite を .db に変換
          if (lowerName.endsWith('.sqlite')) {
            exportName = p.basenameWithoutExtension(name) + '.db';
          } else if (lowerName.endsWith('.sqlite-journal')) {
            exportName =
                p.basenameWithoutExtension(p.basenameWithoutExtension(name)) +
                    '.db-journal';
          }
        }

        try {
          final bytes = await entity.readAsBytes();

          List<int> processedBytes;

          // 通常の処理
          // Android版もiOS版も、myalltracks.backup 内のファイルは平文SQLiteを期待
          // 本アプリ内の .db ファイルは暗号化されているため、エクスポート時に復号
          // .sqlite ファイルは平文のためそのまま → .db にリネーム

          List<int> currentBytes;
          if (lowerName.endsWith('.db') || lowerName.endsWith('.db-journal')) {
            // 暗号化されているので復号して出力（Android版は暗号化されたファイルを期待するため、ここで復号＝平文に戻す？）
            // いや、Android版はXOR 0x55を期待している。
            // 本アプリ内のDBが平文なら、_xorProcessで暗号化される。
            // 本アプリ内のDBが暗号化なら、_xorProcessで平文になる。
            // ここはこれまでのロジックを踏襲する。
            currentBytes = _xorProcess(bytes);
          } else {
            // .sqlite 系は平文なのでそのまま
            currentBytes = bytes;
          }

          // iOS → Android 互換性: hm_*.db ファイル および ue3.db に android_metadata を追加
          // ユーザー要望により ue3.db はリネームせずそのまま使用するが、メタデータは追加しておく方が安全
          if ((exportName.startsWith('hm_') && exportName.endsWith('.db')) ||
              exportName == 'ue3.db') {
            // ここでは currentBytes は「アーカイブに格納される直前の状態」
            // もし _xorProcess で暗号化されているなら、一旦復号が必要。
            // しかし、本アプリ内が平文で _xorProcess で暗号化しているなら、
            // まだファイル書き込み前なので _xorProcess 前の bytes を使えば平文のはず。

            // 一旦一時ファイルに書き出す
            final tempDir = await getTemporaryDirectory();
            final tempHmPath = p.join(tempDir.path,
                'temp_db_process_${DateTime.now().microsecondsSinceEpoch}.db');

            // bytes は平文のはず（本アプリ内DBが平文なら）。
            await File(tempHmPath).writeAsBytes(bytes);

            bool modified = false;
            try {
              final db = await openDatabase(tempHmPath);

              // android_metadata チェック
              final count = Sqflite.firstIntValue(await db.rawQuery(
                  "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='android_metadata'"));

              if (count == 0) {
                await db.execute('CREATE TABLE android_metadata (locale TEXT)');
                await db.execute(
                    "INSERT INTO android_metadata (locale) VALUES ('ja_JP')");
                modified = true;
              }

              await db.close();
            } catch (e) {
              // debugPrint('Failed to add metadata to $exportName: $e');
              // おそらく暗号化されていた、あるいは破損。無視して元のデータを使う。
            }

            if (modified) {
              final newBytes = await File(tempHmPath).readAsBytes();
              // 修正された平文データを暗号化
              processedBytes = _xorProcess(newBytes);
            } else {
              processedBytes = currentBytes;
            }

            await File(tempHmPath).delete();
          } else {
            processedBytes = currentBytes;
          }

          final archiveFile =
              ArchiveFile(exportName, processedBytes.length, processedBytes);
          innerArchive.addFile(archiveFile);
          dbCount++;
        } catch (e) {
          debugPrint('Error processing file $name: $e');
        }
      }
    }

    if (dbCount == 0) {
      debugPrint('No database files found to export.');
      return;
    }

    // 1.5. .db-journal ファイルが存在しない .db ファイルに対して空の journal を生成
    // (iOS → Android 互換性のため)
    final dbFilesInArchive = <String>{};
    final journalFilesInArchive = <String>{};

    for (var file in innerArchive.files) {
      final name = file.name;
      if (name.endsWith('.db')) {
        dbFilesInArchive.add(name);
      } else if (name.endsWith('.db-journal')) {
        // .db-journal から .db の名前を取得
        final dbName = name.substring(0, name.length - 8); // "-journal" を除去
        journalFilesInArchive.add(dbName);
      }
    }

    // 1.6. iOS元データの場合、必須DBファイルが無ければ生成
    // (Android版マッピングアプリとの互換性のため)
    final allDbFiles = dbFilesInArchive.toList();

    // area3.db が無い場合、生成
    if (Area3DbGenerator.needsArea3Db(allDbFiles)) {
      debugPrint('Generating missing area3.db for Android compatibility...');

      // 一時ファイルとして生成
      final tempDir = await getTemporaryDirectory();
      final area3Path = p.join(tempDir.path, 'area3_temp.db');

      final area3Bytes = await Area3DbGenerator.generateEmptyArea3Db(area3Path);

      // 平文で出力（Android版は平文を期待）
      final area3Data = area3Bytes;

      // アーカイブに追加
      final area3File = ArchiveFile('area3.db', area3Data.length, area3Data);
      innerArchive.addFile(area3File);

      // journal も追加
      final area3Journal = JournalGenerator.generateEmptyJournal();
      final area3JournalFile =
          ArchiveFile('area3.db-journal', area3Journal.length, area3Journal);
      innerArchive.addFile(area3JournalFile);

      // 一時ファイル削除
      await File(area3Path).delete();

      debugPrint('Generated area3.db and area3.db-journal');
    }

    // ue3.db が無い場合、生成（空のuserevent3_table）
    if (Area3DbGenerator.needsUe3Db(allDbFiles)) {
      debugPrint('Generating missing ue3.db for Android compatibility...');

      final tempDir = await getTemporaryDirectory();
      final ue3Path = p.join(tempDir.path, 'ue3_temp_gen.db');

      final ue3Bytes = await Area3DbGenerator.generateEmptyUe3Db(ue3Path);

      // 暗号化（Android版マッピングアプリは暗号化されたファイルを期待）
      // ※ ue3.db はiOS版では平文だったが、Android版では area3.db とペアで存在し、
      // どちらも暗号化されている可能性があるため、暗号化しておくのが安全
      final encryptedUe3 = _xorProcess(ue3Bytes);

      // アーカイブに追加
      final ue3File = ArchiveFile('ue3.db', encryptedUe3.length, encryptedUe3);
      innerArchive.addFile(ue3File);

      // journal も追加
      final ue3Journal = JournalGenerator.generateEmptyJournal();
      final ue3JournalFile =
          ArchiveFile('ue3.db-journal', ue3Journal.length, ue3Journal);
      innerArchive.addFile(ue3JournalFile);

      await File(ue3Path).delete();
      debugPrint('Generated ue3.db and ue3.db-journal');
    }

    // google_app_measurement_local.db が無い場合、生成
    if (Area3DbGenerator.needsGoogleMeasurementDb(allDbFiles)) {
      debugPrint('Generating missing google_app_measurement_local.db...');

      final tempDir = await getTemporaryDirectory();
      final googlePath = p.join(tempDir.path, 'google_temp.db');

      final googleBytes =
          await Area3DbGenerator.generateEmptyGoogleMeasurementDb(googlePath);

      // 暗号化
      final encryptedGoogle = _xorProcess(googleBytes);

      // アーカイブに追加
      final googleFile = ArchiveFile('google_app_measurement_local.db',
          encryptedGoogle.length, encryptedGoogle);
      innerArchive.addFile(googleFile);

      // journal も追加
      final googleJournal = JournalGenerator.generateEmptyJournal();
      final googleJournalFile = ArchiveFile(
          'google_app_measurement_local.db-journal',
          googleJournal.length,
          googleJournal);
      innerArchive.addFile(googleJournalFile);

      // 一時ファイル削除
      await File(googlePath).delete();

      debugPrint('Generated google_app_measurement_local.db and journal');
    }

    // 2. 第一段階ZIPをエンコード
    final innerZipBytes = ZipEncoder().encode(innerArchive);
    if (innerZipBytes == null) {
      throw Exception('Failed to encode inner archive.');
    }

    // 3. ヘッダー付与して myalltracks.backup を作成
    const headerStr = "MyAllTracksBackup.v0001:";
    final headerBytes = headerStr.codeUnits;
    final backupBytes = Uint8List(headerBytes.length + innerZipBytes.length);
    backupBytes.setRange(0, headerBytes.length, headerBytes);
    backupBytes.setRange(headerBytes.length, backupBytes.length, innerZipBytes);

    // 4. 外側のアーカイブ作成 (MyAllTracks/ 構造)
    final outerArchive = Archive();

    // myalltracks.backup を MyAllTracks/ 配下に追加
    final backupFile = ArchiveFile(
        'MyAllTracks/myalltracks.backup', backupBytes.length, backupBytes);
    outerArchive.addFile(backupFile);

    // 5. imgs フォルダがあれば追加
    final imgsDir = Directory(p.join(dbBasePath, 'imgs'));
    if (await imgsDir.exists()) {
      final imgFiles = imgsDir.listSync(recursive: true);
      for (var imgEntity in imgFiles) {
        if (imgEntity is File) {
          try {
            final bytes = await imgEntity.readAsBytes();
            final relativePath = p.relative(imgEntity.path, from: dbBasePath);
            final archivePath = 'MyAllTracks/$relativePath';
            final imgFile = ArchiveFile(archivePath, bytes.length, bytes);
            outerArchive.addFile(imgFile);
          } catch (e) {
            debugPrint('Error adding image file: $e');
          }
        }
      }
    }

    // 6. 最終的な .mapping ファイルを作成
    final mappingBytes = ZipEncoder().encode(outerArchive);
    if (mappingBytes == null) {
      throw Exception('Failed to encode outer archive.');
    }

    // 7. 一時ファイルとして保存
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final exportPath = p.join(tempDir.path, 'export_$timestamp.mapping');
    final exportFile = File(exportPath);
    await exportFile.writeAsBytes(mappingBytes);

    debugPrint(
        'Created export file: $exportPath (${mappingBytes.length} bytes)');

    // 8. エクスポート先を選択可能にする
    await Share.shareXFiles(
      [XFile(exportPath)],
      text: 'Mapping Data Export',
      subject: 'export_$timestamp.mapping',
    );
  }
}

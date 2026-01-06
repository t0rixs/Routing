import 'dart:typed_data';

/// SQLite .db-journal ファイル生成ユーティリティ
///
/// Android版マッピングアプリとの互換性のため、
/// iOS版データ（journal無し）をエクスポートする際に使用します。
class JournalGenerator {
  /// 暗号化キー (XOR)
  static const int _xorKey = 0x55;

  /// Android版マッピングアプリ互換の .db-journal ファイルを生成
  ///
  /// Android版の .db-journal ファイルは以下の特徴があります：
  /// - サイズ: 512バイト固定
  /// - 内容: 全バイトが 0x55 (空データを XOR 暗号化したもの)
  ///
  /// これは「トランザクション無し（コミット済み）」を示す
  /// 空のジャーナルファイルの暗号化形式です。
  ///
  /// Returns: 512バイトの Uint8List (全バイト 0x55)
  static Uint8List generateEmptyJournal() {
    // 512バイトの空データ (0x00) を XOR 暗号化
    // 0x00 XOR 0x55 = 0x55
    return Uint8List(512)..fillRange(0, 512, _xorKey);
  }

  /// 指定されたサイズの journal ファイルを生成
  ///
  /// 通常は [generateEmptyJournal] を使用してください。
  /// このメソッドは特殊なケース（異なるサイズが必要な場合）用です。
  ///
  /// [size]: ジャーナルファイルのサイズ（バイト）
  /// Returns: 指定サイズの Uint8List (全バイト 0x55)
  static Uint8List generateJournalWithSize(int size) {
    return Uint8List(size)..fillRange(0, size, _xorKey);
  }

  /// journal ファイルが有効な形式かチェック
  ///
  /// Android版の有効な journal は：
  /// - サイズが512バイトの倍数
  /// - 全バイトが 0x55
  ///
  /// [data]: チェック対象のバイト列
  /// Returns: 有効な journal 形式なら true
  static bool isValidJournal(Uint8List data) {
    // サイズチェック（512の倍数）
    if (data.length % 512 != 0) {
      return false;
    }

    // 全バイトが 0x55 かチェック
    for (var byte in data) {
      if (byte != _xorKey) {
        return false;
      }
    }

    return true;
  }

  /// journal ファイル名を .db ファイル名から生成
  ///
  /// 例: "hm_16_645_1605.db" → "hm_16_645_1605.db-journal"
  ///
  /// [dbFileName]: .db ファイル名
  /// Returns: 対応する .db-journal ファイル名
  static String getJournalFileName(String dbFileName) {
    if (!dbFileName.endsWith('.db')) {
      throw ArgumentError('Invalid .db file name: $dbFileName');
    }
    return '$dbFileName-journal';
  }

  /// .db-journal ファイル名から .db ファイル名を取得
  ///
  /// 例: "hm_16_645_1605.db-journal" → "hm_16_645_1605.db"
  ///
  /// [journalFileName]: .db-journal ファイル名
  /// Returns: 対応する .db ファイル名
  static String getDbFileName(String journalFileName) {
    if (!journalFileName.endsWith('.db-journal')) {
      throw ArgumentError('Invalid .db-journal file name: $journalFileName');
    }
    return journalFileName.substring(0, journalFileName.length - 8);
  }
}

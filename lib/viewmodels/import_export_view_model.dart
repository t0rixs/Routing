import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart'; // getDatabasesPathのために必要
import '../repositories/file_repository.dart';
import '../repositories/database_repository.dart';

/// インポート・エクスポートの状態を管理するViewModel
class ImportExportViewModel extends ChangeNotifier {
  final FileRepository _fileRepository = FileRepository();
  final DatabaseRepository _databaseRepository = DatabaseRepository();

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _successMessage;
  String? get successMessage => _successMessage;

  /// .mappingファイルのインポートを実行
  Future<void> importFile(String filePath) async {
    _setLoading(true);
    _clearMessages();

    try {
      final dbPath = await getDatabasesPath();

      // インポート処理 (FileRepository内で自動リネームが走る)
      await _fileRepository.importMappingFile(filePath, dbPath);

      _successMessage = 'Import successful!';

      // DBリポジトリに再スキャンを依頼 (新しいファイルを認識させるため)
      // _databaseRepository.scanExistingDatabases() などを呼ぶとベターだが、
      // MapViewModelが再描画時に勝手に開くので、ここではログ出力確認程度でOK。
      await _databaseRepository.scanExistingDatabases();

      notifyListeners();
    } catch (e) {
      _errorMessage = 'Import failed: $e';
      debugPrint(_errorMessage);
      notifyListeners();
    } finally {
      _setLoading(false);
    }
  }

  /// (未実装) エクスポート処理
  /// エクスポート処理
  Future<void> exportFile() async {
    _setLoading(true);
    _clearMessages();

    try {
      // 全てのDB接続を閉じて、WAL等をマージ・フラッシュさせる
      await _databaseRepository.closeAll();

      final dbPath = await getDatabasesPath();
      await _fileRepository.exportMappingFile(dbPath);
      _successMessage = 'Export successful!';
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Export failed: $e';
      debugPrint(_errorMessage);
      notifyListeners();
    } finally {
      _setLoading(false);
    }
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _clearMessages() {
    _errorMessage = null;
    _successMessage = null;
    notifyListeners();
  }
}

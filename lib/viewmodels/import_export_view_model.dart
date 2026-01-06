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

  double _progress = 0.0;
  double get progress => _progress;

  int _processedFiles = 0;
  int get processedFiles => _processedFiles;

  int _totalFiles = 0;
  int get totalFiles => _totalFiles;

  /// .mappingファイルのインポートを実行
  Future<void> importFile(String filePath) async {
    _setLoading(true);
    _clearMessages();
    _resetProgress();

    try {
      final dbPath = await getDatabasesPath();

      // インポート処理 (FileRepository内で自動リネームが走る)
      await _fileRepository.importMappingFile(filePath, dbPath,
          onProgress: _updateProgress);

      _successMessage = 'Import successful!';

      // DBリポジトリに再スキャンを依頼
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

  /// エクスポート処理（Android・iOS両対応）
  Future<void> exportFile() async {
    _setLoading(true);
    _clearMessages();
    _resetProgress();

    try {
      // 全てのDB接続を閉じて、WAL等をマージ・フラッシュさせる
      await _databaseRepository.closeAll();

      final dbPath = await getDatabasesPath();
      await _fileRepository.exportMappingFile(dbPath,
          onProgress: _updateProgress);
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

  void _updateProgress(int processed, int total) {
    _processedFiles = processed;
    _totalFiles = total;
    if (total > 0) {
      _progress = processed / total;
    } else {
      _progress = 0.0;
    }
    notifyListeners();
  }

  void _resetProgress() {
    _progress = 0.0;
    _processedFiles = 0;
    _totalFiles = 0;
    notifyListeners();
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

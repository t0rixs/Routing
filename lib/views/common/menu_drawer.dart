import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../viewmodels/import_export_view_model.dart';
import '../../viewmodels/map_view_model.dart';

class MenuDrawer extends StatelessWidget {
  const MenuDrawer({super.key});

  /// Import の二重起動（file_picker の PlatformException(already_active) 対策）
  static bool _isImporting = false;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.blue),
            child: Text('Routing Menu',
                style: TextStyle(color: Colors.white, fontSize: 24)),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload),
            title: const Text('Import .mapping'),
            onTap: () async {
              // 二重起動ガード: file_picker が別の呼び出しを処理中だと
              // PlatformException(already_active) が返るため
              if (_isImporting) {
                debugPrint('Menu: Import already in progress, ignored.');
                Navigator.pop(context);
                return;
              }
              _isImporting = true;

              // Contextが有効なうちにViewModel・Navigator・Messenger を取得しておく
              final importVm =
                  Provider.of<ImportExportViewModel>(context, listen: false);
              final mapVm = Provider.of<MapViewModel>(context, listen: false);
              final messenger = ScaffoldMessenger.of(context);
              // NavigatorState を事前に捕捉（準備ダイアログの pop で使用）
              final navigator = Navigator.of(context, rootNavigator: true);

              Navigator.pop(context); // Close drawer

              debugPrint('Menu: Import tapped, drawer closed. Waiting...');

              // ファイルピッカー起動
              // "File picker already active" エラー回避のため少し待つ
              await Future.delayed(const Duration(milliseconds: 500));

              bool prepDialogShown = false;

              try {
                debugPrint('Menu: Opening file picker...');
                final result =
                    await FilePicker.platform.pickFiles(type: FileType.any);

                if (result != null && result.files.single.path != null) {
                  final path = result.files.single.path!;
                  debugPrint('Menu: File picked: $path');

                  // importFile 内部の同期重処理（ZIP 展開など）でメインスレッドが
                  // ブロックされ、ImportExportViewModel 経由のオーバーレイ描画が
                  // 遅延するケースへの保険として、ここで即時ダイアログを起動する。
                  // await しないことで非同期に描画キューへ積まれ、直後の
                  // importFile 呼び出しより先にフレームが描画される。
                  if (context.mounted) {
                    prepDialogShown = true;
                    // ignore: use_build_context_synchronously
                    showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const _ImportPrepDialog(),
                    );
                    // 1 フレーム譲って、ダイアログが確実に表示されてから
                    // 重処理に突入する。
                    await WidgetsBinding.instance.endOfFrame;
                  }

                  try {
                    await importVm.importFile(path);
                  } finally {
                    if (prepDialogShown) {
                      navigator.pop();
                      prepDialogShown = false;
                    }
                  }

                  if (importVm.successMessage != null) {
                    debugPrint('Menu: Import success');
                    messenger.showSnackBar(
                      SnackBar(content: Text(importVm.successMessage!)),
                    );
                    mapVm.refreshMap();
                  } else if (importVm.errorMessage != null) {
                    debugPrint('Menu: Import failed: ${importVm.errorMessage}');
                    messenger.showSnackBar(
                      SnackBar(
                          content: Text(importVm.errorMessage!),
                          backgroundColor: Colors.red),
                    );
                  }
                } else {
                  debugPrint('Menu: File picker cancelled or no file selected');
                }
              } catch (e) {
                if (prepDialogShown) {
                  navigator.pop();
                  prepDialogShown = false;
                }
                debugPrint('Pick file error: $e');
                messenger.showSnackBar(
                  SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: Colors.red),
                );
              } finally {
                _isImporting = false;
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download),
            title: const Text('Export .mapping'),
            subtitle: const Text('Android・iOS両対応'),
            onTap: () async {
              Navigator.pop(context); // Close drawer

              final importVm =
                  Provider.of<ImportExportViewModel>(context, listen: false);

              // エクスポート実行
              await importVm.exportFile();

              if (!context.mounted) return;

              if (importVm.successMessage != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(importVm.successMessage!)),
                );
              } else if (importVm.errorMessage != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(importVm.errorMessage!),
                      backgroundColor: Colors.red),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

/// インポート開始直後に表示する軽量ダイアログ。
/// `ImportExportViewModel` のオーバーレイが現れるまでのギャップを埋める役割。
class _ImportPrepDialog extends StatelessWidget {
  const _ImportPrepDialog();

  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      content: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Text('インポート準備中...\nファイルを展開しています'),
          ),
        ],
      ),
    );
  }
}

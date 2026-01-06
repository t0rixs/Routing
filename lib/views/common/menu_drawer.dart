import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../viewmodels/import_export_view_model.dart';
import '../../viewmodels/map_view_model.dart';

class MenuDrawer extends StatelessWidget {
  const MenuDrawer({super.key});

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
              // Contextが有効なうちにViewModelを取得しておく
              final importVm =
                  Provider.of<ImportExportViewModel>(context, listen: false);
              final mapVm = Provider.of<MapViewModel>(context, listen: false);

              Navigator.pop(context); // Close drawer

              debugPrint('Menu: Import tapped, drawer closed. Waiting...');

              // ファイルピッカー起動
              // "File picker already active" エラー回避のため少し待つ
              await Future.delayed(const Duration(milliseconds: 500));

              try {
                debugPrint('Menu: Opening file picker...');
                final result =
                    await FilePicker.platform.pickFiles(type: FileType.any);

                if (result != null && result.files.single.path != null) {
                  final path = result.files.single.path!;
                  debugPrint('Menu: File picked: $path');

                  // ViewModel経由でインポート実行
                  await importVm.importFile(path);

                  if (importVm.successMessage != null) {
                    debugPrint('Menu: Import success');
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(importVm.successMessage!)),
                      );
                    }
                    // マップリフレッシュ
                    mapVm.refreshMap();
                  } else if (importVm.errorMessage != null) {
                    debugPrint('Menu: Import failed: ${importVm.errorMessage}');
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(importVm.errorMessage!),
                            backgroundColor: Colors.red),
                      );
                    }
                  }
                } else {
                  debugPrint('Menu: File picker cancelled or no file selected');
                }
              } catch (e) {
                debugPrint('Pick file error: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text('Error: $e'),
                        backgroundColor: Colors.red),
                  );
                }
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

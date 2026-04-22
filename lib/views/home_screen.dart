import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'map/map_widget_adaptive.dart';
import 'common/menu_drawer.dart';
import 'common/background_activity_pill.dart';
import '../../viewmodels/import_export_view_model.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const MenuDrawer(),
      body: Stack(
        children: [
          const MapWidgetAdaptive(),
          // 背景処理の存在を示す画面上部のピル。操作はブロックしない。
          const BackgroundActivityPill(),
          // ローディングインジケータ
          Consumer<ImportExportViewModel>(
            builder: (context, vm, child) {
              if (vm.isLoading) {
                // ファイル展開フェーズ（totalFiles == 0）は進捗率が未確定なので
                // CircularProgressIndicator（無限スピナー）を表示する。
                // 展開後の書き出しフェーズに入り次第 LinearProgressIndicator に切替。
                final bool indeterminate = vm.totalFiles == 0;
                return Container(
                  color: Colors.black54,
                  child: Center(
                    child: Card(
                      margin: const EdgeInsets.symmetric(horizontal: 32),
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Processing Data...',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 20),
                            if (indeterminate) ...[
                              const SizedBox(
                                width: 48,
                                height: 48,
                                child: CircularProgressIndicator(),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'ファイルを展開中...',
                                style: TextStyle(fontSize: 14),
                              ),
                            ] else ...[
                              LinearProgressIndicator(
                                value: vm.processedFiles / vm.totalFiles,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '${vm.processedFiles} / ${vm.totalFiles} files',
                                style: const TextStyle(fontSize: 16),
                              ),
                              if (vm.progress > 0)
                                Text(
                                  '${(vm.progress * 100).toStringAsFixed(1)}%',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      floatingActionButton: Builder(builder: (context) {
        return FloatingActionButton(
          child: const Icon(Icons.menu),
          onPressed: () {
            Scaffold.of(context).openDrawer();
          },
        );
      }),
    );
  }
}

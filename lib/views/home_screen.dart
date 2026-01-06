import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'map/map_widget.dart';
import 'common/menu_drawer.dart';
import '../../viewmodels/import_export_view_model.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const MenuDrawer(),
      body: Stack(
        children: [
          const MapWidget(),
          // ローディングインジケータ
          Consumer<ImportExportViewModel>(
            builder: (context, vm, child) {
              if (vm.isLoading) {
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
                            LinearProgressIndicator(
                              value: vm.totalFiles > 0
                                  ? vm.processedFiles / vm.totalFiles
                                  : null,
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

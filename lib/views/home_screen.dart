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
      appBar: AppBar(
        title: const Text('Routing App (MVVM)'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        // Drawerアイコンは自動で付くが、FABでメニューを開くならAppBarは非表示でも良い。
        // ここでは標準的なDrawer使用とする。
      ),
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
                  child: const Center(
                    child: CircularProgressIndicator(),
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

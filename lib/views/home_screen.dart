import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../generated/l10n/app_localizations.dart';
import 'map/map_widget_adaptive.dart';
import 'common/menu_drawer.dart';
import 'common/background_activity_pill.dart';
import 'common/banner_ad_widget.dart';
import 'common/location_always_prompt.dart';
import 'common/location_rationale_prompt.dart';
import '../../viewmodels/import_export_view_model.dart';
import '../../services/update_checker.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // 起動時に Play In-App Update を確認（Android リリースビルドのみ実行）。
    // build 後の最初のフレームで実行することで、SnackBar 表示用の Scaffold が
    // 確実にツリー上に存在する状態を保証する。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        UpdateChecker.checkAndPromptUpdate(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 広告バーは Scaffold の外側（Column の子）に置く。こうすることで Drawer
    // (menu) は広告バーを含まない上段の Scaffold にだけ載り、メニューが広告に
    // 被らない。
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Scaffold(
              // 左側からスライドインする通常の Drawer。
              // 画面上の設定 FAB（map_widget 内）から openDrawer() で開く。
              drawer: const MenuDrawer(),
              body: Stack(
                children: [
                  const MapWidgetAdaptive(),
                  // 背景処理の存在を示す画面上部のピル。操作はブロックしない。
                  const BackgroundActivityPill(),
                  // 初回起動時の位置情報利用目的の事前説明ダイアログ。
                  const LocationRationalePrompt(),
                  // 位置情報の「常に許可」誘導ダイアログ（必要時のみ表示）。
                  const LocationAlwaysPrompt(),
                  // ローディングインジケータ
                  Consumer<ImportExportViewModel>(
                    builder: (context, vm, child) {
                      final l = AppLocalizations.of(context)!;
                      if (vm.isLoading) {
                        // ファイル展開フェーズ（totalFiles == 0）は進捗率が未確定なので
                        // CircularProgressIndicator（無限スピナー）を表示する。
                        // 展開後の書き出しフェーズに入り次第 LinearProgressIndicator に切替。
                        final bool indeterminate = vm.totalFiles == 0;
                        return Container(
                          color: Colors.black54,
                          child: Center(
                            child: Card(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 32),
                              child: Padding(
                                padding: const EdgeInsets.all(24.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(l.loading,
                                        style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 20),
                                    if (indeterminate) ...[
                                      const SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: CircularProgressIndicator(),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        l.extractingFiles,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ] else ...[
                                      LinearProgressIndicator(
                                        value: vm.processedFiles /
                                            vm.totalFiles,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        '${vm.processedFiles} / ${vm.totalFiles} files',
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                      if (vm.progress > 0)
                                        Text(
                                          '${(vm.progress * 100).toStringAsFixed(1)}%',
                                          style: const TextStyle(
                                              color: Colors.grey),
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
              // floatingActionButton は map_widget 側に移動した。
              // menu FAB → 画面上ボタン群を展開、設定 FAB → endDrawer を開く。
            ),
          ),
          const SafeArea(
            top: false,
            child: BannerAdWidget(),
          ),
        ],
      ),
    );
  }
}

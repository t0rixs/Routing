import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../viewmodels/map_view_model.dart';

/// `MapViewModel.locationAlwaysRequired` を監視し、true になったら
/// 「常に許可」への誘導ダイアログを 1 度だけ表示する。
///
/// ダイアログ上の「設定を開く」ボタンは OS の設定画面を開く。
/// 閉じる時は `clearLocationAlwaysRequired` を呼んでフラグを落とす。
class LocationAlwaysPrompt extends StatefulWidget {
  const LocationAlwaysPrompt({super.key});

  @override
  State<LocationAlwaysPrompt> createState() => _LocationAlwaysPromptState();
}

class _LocationAlwaysPromptState extends State<LocationAlwaysPrompt> {
  bool _dialogShowing = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, vm, _) {
        if (vm.locationAlwaysRequired && !_dialogShowing) {
          _dialogShowing = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showDialog(context, vm);
          });
        }
        return const SizedBox.shrink();
      },
    );
  }

  Future<void> _showDialog(BuildContext context, MapViewModel vm) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('位置情報を「常に許可」に設定してください'),
        content: const Text(
          'このアプリは、アプリを閉じている間も走行ルートを記録するために、'
          '位置情報の「常に許可」が必要です。\n\n'
          '設定画面の「位置情報」を開き、「常に」を選択してください。',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
            },
            child: const Text('あとで'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await Geolocator.openAppSettings();
            },
            child: const Text('設定を開く'),
          ),
        ],
      ),
    );
    vm.clearLocationAlwaysRequired();
    if (mounted) {
      setState(() {
        _dialogShowing = false;
      });
    }
  }
}

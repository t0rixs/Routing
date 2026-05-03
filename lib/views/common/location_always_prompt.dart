import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../generated/l10n/app_localizations.dart';
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
    final l = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l.locationAlwaysTitle),
        content: Text(l.locationAlwaysBody),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
            },
            child: Text(l.later),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await openAppSettings();
            },
            child: Text(l.openSettings),
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../viewmodels/map_view_model.dart';

/// アプリ起動直後、OS の位置情報許可ダイアログを出す前に表示する事前説明
/// ダイアログ。
///
/// 目的:
/// - ユーザに対して「なぜバックグラウンドで位置情報を使うのか」を
///   分かりやすく説明し、納得して OS 許可ダイアログの「常に許可」を
///   選べるようにする（Play/App Store 審査要件にも合致）。
///
/// `MapViewModel.needsLocationRationale` が true のときに自動で開き、
/// 「OK（続ける）」を押すと `acknowledgeLocationRationale()` を呼んで
/// 許可フローを再開する。初回の 1 回だけ表示される。
class LocationRationalePrompt extends StatefulWidget {
  const LocationRationalePrompt({super.key});

  @override
  State<LocationRationalePrompt> createState() =>
      _LocationRationalePromptState();
}

class _LocationRationalePromptState extends State<LocationRationalePrompt> {
  bool _dialogShowing = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, vm, _) {
        if (vm.needsLocationRationale && !_dialogShowing) {
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
        title: const Text('位置情報の利用について'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'このアプリはローカルに移動ログを保存するため、'
                'バックグラウンドで位置情報を使用します。',
                style: TextStyle(fontSize: 15),
              ),
              SizedBox(height: 12),
              Text(
                '取得した位置情報はあなたの端末内にのみ保存され、'
                'サーバには送信されません。',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              SizedBox(height: 12),
              Text(
                '次に OS の許可ダイアログが表示されます。'
                'バックグラウンドでも記録するためには「常に許可」を選択してください。',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
            },
            child: const Text('OK（続ける）'),
          ),
        ],
      ),
    );
    await vm.acknowledgeLocationRationale();
    if (mounted) {
      setState(() {
        _dialogShowing = false;
      });
    }
  }
}

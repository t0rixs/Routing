import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';

/// Google Play In-App Updates によるアップデート通知サービス。
///
/// Android のみ動作。iOS / Web では何もしない。
/// アップデートが利用可能なら Flexible Update のフローを開始し、
/// ダウンロード完了後にユーザに再起動を促す。
class UpdateChecker {
  UpdateChecker._();

  static bool _checked = false;

  /// アプリ起動時などに呼び出してアップデートの有無を確認し、
  /// 利用可能ならユーザに通知して Flexible Update を開始する。
  ///
  /// 二重実行防止のため一度だけ実行される。
  static Future<void> checkAndPromptUpdate(BuildContext context) async {
    if (_checked) return;
    _checked = true;
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability != UpdateAvailability.updateAvailable) {
        return;
      }
      if (info.flexibleUpdateAllowed) {
        final result = await InAppUpdate.startFlexibleUpdate();
        if (result == AppUpdateResult.success) {
          await InAppUpdate.completeFlexibleUpdate();
        }
      } else if (info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
      }
    } catch (_) {
      // 失敗しても起動を妨げない（ストア外配布／ネットワーク不通など）。
    }
  }
}

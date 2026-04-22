import 'package:flutter/material.dart';

import '../../services/background_activity_service.dart';

/// 画面上部に表示される「処理中」ピル。
/// - 操作をブロックしない (IgnorePointer でタップを透過)
/// - `BackgroundActivityService.isActive` が true の間だけフェードイン
/// - ピル自体のレンダリングは極めて軽量なので、処理がある限り常時表示する
class BackgroundActivityPill extends StatelessWidget {
  const BackgroundActivityPill({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AnimatedBuilder(
              animation: BackgroundActivityService.instance,
              builder: (context, _) {
                final bool active =
                    BackgroundActivityService.instance.isActive;
                return AnimatedOpacity(
                  opacity: active ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: const _PillChip(),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _PillChip extends StatelessWidget {
  const _PillChip();

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(20),
      color: Colors.black.withValues(alpha: 0.72),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            SizedBox(width: 8),
            Text(
              '処理中',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

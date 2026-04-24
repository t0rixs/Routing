import 'package:flutter/material.dart';

import '../../services/background_activity_service.dart';

/// 画面上部に表示される「処理中」インジケータ。
/// - 操作をブロックしない (IgnorePointer でタップを透過)
/// - `BackgroundActivityService.isActive` が true の間だけフェードイン
/// - 文字は出さず右上に小さなスピナーのみ（セル数 HUD とかぶらないため）
class BackgroundActivityPill extends StatelessWidget {
  const BackgroundActivityPill({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 12),
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
      color: Colors.black.withValues(alpha: 0.55),
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(Colors.white),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

/// アプリ全体で発生している「バックグラウンド処理の有無」を表すサービス。
///
/// 利用側は `begin()` / `end()` で区間を登録するだけでよく、種別は区別しない。
/// 主な呼び出し元:
///   - `TileRasterizerPool.rasterize` (タイル描画の isolate ジョブ)
///   - `MapViewModel.requestViewportPrefetch` (shard プリフェッチ)
///   - その他 DB 操作など、ユーザに「今何か走ってますよ」と見せたい区間
///
/// 挙動:
///   - 最初の `begin()` で即座に可視状態になる (ユーザに即時フィードバック)
///   - `end()` で参照カウンタが 0 になっても [_hideCooldown] だけ可視を維持し、
///     連続した短い処理で点滅しないようにする。
///   - `notifyListeners()` は状態が本当に変わった瞬間だけ発火させるので、
///     `begin()`/`end()` を毎フレーム呼んでも UI の rebuild ストームは起きない。
class BackgroundActivityService extends ChangeNotifier {
  BackgroundActivityService._();
  static final BackgroundActivityService instance =
      BackgroundActivityService._();

  /// end 後、hide するまでの待機時間。短い処理が連続した時に
  /// ピルが点滅しないようにするためのクッション。
  static const Duration _hideCooldown = Duration(milliseconds: 400);

  int _count = 0;
  bool _visible = false;
  Timer? _hideTimer;

  bool get isActive => _visible;

  void begin() {
    _count++;
    if (_hideTimer != null) {
      _hideTimer!.cancel();
      _hideTimer = null;
    }
    if (!_visible) {
      _visible = true;
      notifyListeners();
    }
  }

  void end() {
    if (_count > 0) _count--;
    if (_count == 0 && _visible) {
      _hideTimer?.cancel();
      _hideTimer = Timer(_hideCooldown, () {
        _hideTimer = null;
        if (_count == 0 && _visible) {
          _visible = false;
          notifyListeners();
        }
      });
    }
  }

  /// 例外安全にラップしたい場合の糖衣。
  Future<T> run<T>(Future<T> Function() body) async {
    begin();
    try {
      return await body();
    } finally {
      end();
    }
  }
}

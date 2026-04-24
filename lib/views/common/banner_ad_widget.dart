import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// マップ画面下部に表示するバナー広告ウィジェット。
///
/// AdMob の home_bottom_banner 広告ユニットを使用する。
/// デバッグビルド時はテスト広告 ID を使用する。
class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({super.key});

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;

  // 本番用広告ユニット ID
  static const String _androidAdUnitId =
      'ca-app-pub-7385231614068137/1656667953';

  // テスト広告ユニット ID（開発時用）
  // https://developers.google.com/admob/android/test-ads
  static const String _androidTestAdUnitId =
      'ca-app-pub-3940256099942544/6300978111';

  String? get _adUnitId {
    if (kIsWeb) return null;
    if (Platform.isAndroid) {
      return kDebugMode ? _androidTestAdUnitId : _androidAdUnitId;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  void _loadAd() {
    final adUnitId = _adUnitId;
    if (adUnitId == null) return;

    _bannerAd = BannerAd(
      adUnitId: adUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _isLoaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('BannerAd failed to load: $error');
          ad.dispose();
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoaded || _bannerAd == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: _bannerAd!.size.width.toDouble(),
      height: _bannerAd!.size.height.toDouble(),
      child: AdWidget(ad: _bannerAd!),
    );
  }
}

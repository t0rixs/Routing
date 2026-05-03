import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// マップ画面下部に表示するバナー広告ウィジェット。
///
/// AdMob の home_bottom_banner 広告ユニットを使用する。
/// デバッグビルド時はテスト広告 ID を使用する。
///
/// クリック後サスペンド機能：
/// ユーザがバナーをタップした場合、その後 [_suspensionDuration] の間はバナーを
/// 非表示にする。タイムスタンプは SharedPreferences に保存されアプリ再起動後も保持。
class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({super.key});

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;
  bool _suspended = false;
  Timer? _suspensionTimer;

  /// クリック後の広告非表示期間。
  static const Duration _suspensionDuration = Duration(minutes: 10);

  /// SharedPreferences のキー。
  static const String _prefsKey = 'banner_ad_last_click_at_ms';

  // 本番用広告ユニット ID（home_bottom_banner / bottom_banner: 標準バナー）
  static const String _androidAdUnitId =
      'ca-app-pub-7385231614068137/1839413049';
  static const String _iosAdUnitId =
      'ca-app-pub-7385231614068137/4789529539';

  // テスト広告ユニット ID（開発時用）
  // https://developers.google.com/admob/android/test-ads
  // https://developers.google.com/admob/ios/test-ads
  static const String _androidTestAdUnitId =
      'ca-app-pub-3940256099942544/6300978111';
  static const String _iosTestAdUnitId =
      'ca-app-pub-3940256099942544/2934735716';

  String? get _adUnitId {
    if (kIsWeb) return null;
    if (Platform.isAndroid) {
      return kDebugMode ? _androidTestAdUnitId : _androidAdUnitId;
    }
    if (Platform.isIOS) {
      return kDebugMode ? _iosTestAdUnitId : _iosAdUnitId;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initSuspensionState();
  }

  /// 起動時にサスペンド状態を復元し、有効期間内なら広告ロードをスキップする。
  Future<void> _initSuspensionState() async {
    final prefs = await SharedPreferences.getInstance();
    final lastClickMs = prefs.getInt(_prefsKey);
    if (lastClickMs != null) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - lastClickMs;
      final remaining = _suspensionDuration.inMilliseconds - elapsed;
      if (remaining > 0) {
        if (!mounted) return;
        setState(() => _suspended = true);
        _suspensionTimer =
            Timer(Duration(milliseconds: remaining), _onSuspensionExpired);
        return;
      }
    }
    _loadAd();
  }

  /// サスペンド期間が満了したら広告を再ロードする。
  void _onSuspensionExpired() {
    if (!mounted) return;
    setState(() => _suspended = false);
    _loadAd();
  }

  /// クリックされた時刻を保存し、サスペンドを開始する。
  Future<void> _startSuspension() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey, DateTime.now().millisecondsSinceEpoch);
    _suspensionTimer?.cancel();
    _suspensionTimer = Timer(_suspensionDuration, _onSuspensionExpired);
    _bannerAd?.dispose();
    _bannerAd = null;
    if (!mounted) return;
    setState(() {
      _suspended = true;
      _isLoaded = false;
    });
  }

  void _loadAd() {
    final adUnitId = _adUnitId;
    if (adUnitId == null) return;
    if (_suspended) return;

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
        onAdClicked: (_) {
          // ユーザがバナーをタップした → サスペンドを開始
          _startSuspension();
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _suspensionTimer?.cancel();
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_suspended || !_isLoaded || _bannerAd == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: _bannerAd!.size.width.toDouble(),
      height: _bannerAd!.size.height.toDouble(),
      child: AdWidget(ad: _bannerAd!),
    );
  }
}

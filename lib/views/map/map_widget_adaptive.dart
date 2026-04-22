import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'map_widget.dart' as gmap;
import 'map_widget_flutter_map.dart';

/// プラットフォームに応じて Google Maps 版 / flutter_map 版を切り替えるラッパ。
///
/// - iOS / Android: `google_maps_flutter` を使う従来の [MapWidget]
/// - macOS / Linux / Windows / Web: `flutter_map` ベースの [MapWidgetFlutterMap]
class MapWidgetAdaptive extends StatelessWidget {
  const MapWidgetAdaptive({super.key});

  @override
  Widget build(BuildContext context) {
    final useFlutterMap = kIsWeb ||
        (!kIsWeb &&
            (Platform.isMacOS || Platform.isLinux || Platform.isWindows));
    if (useFlutterMap) {
      return const MapWidgetFlutterMap();
    }
    return const gmap.MapWidget();
  }
}

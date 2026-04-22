import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Zoom 14 のセルインデックス（heatmap と同一の式）
class CellIndex {
  CellIndex._();

  static const int baseZ = 14;

  /// [map_view_model] の onTap / [DatabaseRepository.fetchCells] と同じセルサイズ
  static double cellSizeForZ(int cellZ) =>
      (0.0002 * math.pow(2, 14 - cellZ)).toDouble();

  /// 緯度経度 → Zoom14 のセルインデックス (lat, lng)
  static (int lat, int lng) latLngToIndices14(LatLng p) {
    final double cs = cellSizeForZ(baseZ);
    final int lat = ((p.latitude + 90.0) / cs).floor();
    final int lng = ((p.longitude + 180.0) / cs).floor();
    return (lat, lng);
  }

  /// 線分 [from] → [to] が貫通するすべての Zoom14 セルを返す（始点・終点セル含む）。
  ///
  /// Amanatides & Woo 方式のグリッド走査で、対角線上で飛ばされがちな
  /// セルも確実に列挙する。
  static Set<(int lat, int lng)> cellsOnSegment(LatLng from, LatLng to) {
    final double cs = cellSizeForZ(baseZ);

    // グリッド座標系（x = 経度方向, y = 緯度方向）
    final double x0 = (from.longitude + 180.0) / cs;
    final double y0 = (from.latitude + 90.0) / cs;
    final double x1 = (to.longitude + 180.0) / cs;
    final double y1 = (to.latitude + 90.0) / cs;

    int cx = x0.floor();
    int cy = y0.floor();
    final int endX = x1.floor();
    final int endY = y1.floor();

    final Set<(int, int)> out = {(cy, cx)};
    if (cx == endX && cy == endY) {
      return out;
    }

    final double dx = x1 - x0;
    final double dy = y1 - y0;
    final int stepX = dx > 0 ? 1 : (dx < 0 ? -1 : 0);
    final int stepY = dy > 0 ? 1 : (dy < 0 ? -1 : 0);

    final double tDeltaX = stepX != 0 ? (1.0 / dx.abs()) : double.infinity;
    final double tDeltaY = stepY != 0 ? (1.0 / dy.abs()) : double.infinity;

    double tMaxX;
    if (stepX > 0) {
      tMaxX = ((cx + 1) - x0) / dx;
    } else if (stepX < 0) {
      tMaxX = (x0 - cx) / -dx;
    } else {
      tMaxX = double.infinity;
    }
    double tMaxY;
    if (stepY > 0) {
      tMaxY = ((cy + 1) - y0) / dy;
    } else if (stepY < 0) {
      tMaxY = (y0 - cy) / -dy;
    } else {
      tMaxY = double.infinity;
    }

    // 異常に長い線分を防ぐ安全策
    int guard = 100000;
    while (guard-- > 0) {
      if (tMaxX < tMaxY) {
        if (tMaxX > 1.0) break;
        cx += stepX;
        tMaxX += tDeltaX;
      } else {
        if (tMaxY > 1.0) break;
        cy += stepY;
        tMaxY += tDeltaY;
      }
      out.add((cy, cx));
      if (cx == endX && cy == endY) break;
    }
    return out;
  }
}

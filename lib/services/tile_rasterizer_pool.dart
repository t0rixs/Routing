import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// タイル 1 枚分の描画 (RGBA 塗り) + PNG エンコードを背景 isolate で実行するプール。
///
/// 目的:
///   - `getTile` のホットパスをメインスレッドから完全に切り離す。
///   - 従来は `ui.PictureRecorder` → `picture.toImage` → `toByteData(rawStraightRgba)`
///     という GPU 往復がメインスレッドで走っていたため、ドラッグ中に
///     フレーム落ちが発生していた。
///   - このプールは純粋に CPU (Uint8List 直書き + image パッケージで PNG)
///     で完結するので、メインスレッドの負荷は「パッキング + SendPort の往復」のみになる。
///
/// 仕様:
///   - worker はアプリ起動中生かしたまま (spawn コストを償却)
///   - 受け渡しは `TransferableTypedData` で zero-copy
///   - PNG は level 0 (非圧縮) — 画質劣化なし・CPU 時間最小
class TileRasterizerPool {
  TileRasterizerPool._();
  static final TileRasterizerPool instance = TileRasterizerPool._();

  /// 同時並列で走らせる worker の数。端末の物理コア数に対して 3 で十分
  /// (2〜4 コア環境でも UI スレッドを潰さずに済む現実的な上限)。
  static const int _workerCount = 3;

  final List<_Worker> _workers = <_Worker>[];
  int _rrIndex = 0;
  Future<void>? _initFuture;

  Future<void> _ensureInit() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _spawnAll();
    _initFuture = future;
    return future;
  }

  Future<void> _spawnAll() async {
    for (int i = 0; i < _workerCount; i++) {
      final worker = await _Worker.spawn();
      _workers.add(worker);
    }
  }

  /// 1 タイル分を PNG にして返す。
  ///
  /// - [cells] は Int32List で `[lat0, lng0, val0, lat1, lng1, val1, ...]` の連続表現。
  /// - [highlights] は削除モード時の赤枠対象。`[lat0, lng0, lat1, lng1, ...]`。未使用なら null。
  /// - 返値は PNG のバイト列。セル 0 件の呼び出しは禁止 (main 側で弾く想定)。
  Future<Uint8List> rasterize({
    required int ts,
    required int tileX,
    required int tileY,
    required int tileZ,
    required int cellZ,
    required Int32List cells,
    required bool hideStroke,
    Int32List? highlights,
  }) async {
    await _ensureInit();
    final worker = _workers[_rrIndex];
    _rrIndex = (_rrIndex + 1) % _workers.length;
    return worker.rasterize(
      ts: ts,
      tileX: tileX,
      tileY: tileY,
      tileZ: tileZ,
      cellZ: cellZ,
      cells: cells,
      hideStroke: hideStroke,
      highlights: highlights,
    );
  }
}

class _Worker {
  _Worker._(this._sendPort, this._responses);

  final SendPort _sendPort;
  final Stream<dynamic> _responses;

  int _nextId = 0;
  final Map<int, Completer<Uint8List>> _pending = <int, Completer<Uint8List>>{};

  static Future<_Worker> spawn() async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_entryPoint, receivePort.sendPort);
    final broadcast = receivePort.asBroadcastStream();
    final sendPort = await broadcast.first as SendPort;
    final worker = _Worker._(sendPort, broadcast);
    worker._listen();
    return worker;
  }

  void _listen() {
    _responses.listen((dynamic message) {
      if (message is _RasterizeResponse) {
        final completer = _pending.remove(message.id);
        if (completer != null) {
          if (message.error != null) {
            completer.completeError(message.error!);
          } else {
            completer.complete(message.png!);
          }
        }
      }
    });
  }

  Future<Uint8List> rasterize({
    required int ts,
    required int tileX,
    required int tileY,
    required int tileZ,
    required int cellZ,
    required Int32List cells,
    required bool hideStroke,
    Int32List? highlights,
  }) {
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    final cellsT = TransferableTypedData.fromList(<TypedData>[cells]);
    final hiT = highlights == null
        ? null
        : TransferableTypedData.fromList(<TypedData>[highlights]);
    _sendPort.send(_RasterizeRequest(
      id: id,
      ts: ts,
      tileX: tileX,
      tileY: tileY,
      tileZ: tileZ,
      cellZ: cellZ,
      cells: cellsT,
      hideStroke: hideStroke,
      highlights: hiT,
    ));
    return completer.future;
  }
}

class _RasterizeRequest {
  const _RasterizeRequest({
    required this.id,
    required this.ts,
    required this.tileX,
    required this.tileY,
    required this.tileZ,
    required this.cellZ,
    required this.cells,
    required this.hideStroke,
    required this.highlights,
  });

  final int id;
  final int ts;
  final int tileX;
  final int tileY;
  final int tileZ;
  final int cellZ;
  final TransferableTypedData cells;
  final bool hideStroke;
  final TransferableTypedData? highlights;
}

class _RasterizeResponse {
  const _RasterizeResponse._({
    required this.id,
    this.png,
    this.error,
  });

  factory _RasterizeResponse.success(int id, Uint8List png) =>
      _RasterizeResponse._(id: id, png: png);
  factory _RasterizeResponse.failure(int id, Object error) =>
      _RasterizeResponse._(id: id, error: error);

  final int id;
  final Uint8List? png;
  final Object? error;
}

void _entryPoint(SendPort mainSendPort) {
  final port = ReceivePort();
  mainSendPort.send(port.sendPort);
  port.listen((dynamic message) {
    if (message is _RasterizeRequest) {
      try {
        final png = _rasterizeTile(message);
        mainSendPort.send(_RasterizeResponse.success(message.id, png));
      } catch (e) {
        mainSendPort.send(_RasterizeResponse.failure(message.id, e));
      }
    }
  });
}

Uint8List _rasterizeTile(_RasterizeRequest req) {
  final int ts = req.ts;
  final int tileX = req.tileX;
  final int tileY = req.tileY;
  final int tileZ = req.tileZ;
  final int cellZ = req.cellZ;
  final Int32List cells = req.cells.materialize().asInt32List();
  final Int32List? highlights = req.highlights?.materialize().asInt32List();
  final bool hideStroke = req.hideStroke;

  // RGBA バッファ。Uint8List の新規確保は自動で 0 埋めなので、
  // 透明 (alpha=0) の状態で始まる。セルが塗られない領域はそのまま透明。
  final Uint8List buf = Uint8List(ts * ts * 4);

  // ハイライトの高速参照用セット。lat/lng を int64 キーに畳む。
  // 削除モード時のみ使用 (通常は null で O(1) 無視)。
  Set<int>? hset;
  if (highlights != null && highlights.isNotEmpty) {
    hset = <int>{};
    for (int i = 0; i < highlights.length; i += 2) {
      hset.add(_cellKey(highlights[i], highlights[i + 1]));
    }
  }

  // --- 共通事前計算 -------------------------------------------------
  final double tsD = ts.toDouble();
  final double n = pow(2, tileZ).toDouble(); // tileZ における x/y タイル数
  final double tileOriginX = tileX * tsD;
  final double tileOriginY = tileY * tsD;
  // セルサイズ (度) は z=14 基準の 0.0002 を 2 のべきでスケール。
  final double cellSize = 0.0002 * pow(2, 14 - cellZ).toDouble();
  // 色計算用の上限値 (main 側の `_calculateCellColor` と一致させる)。
  final int maxValue = (14 * pow(2, 14 - cellZ)).floor();
  final int safeMax = maxValue < 1 ? 1 : maxValue;

  // --- セルごとに矩形を塗りつぶす -----------------------------------
  final int cellCount = cells.length ~/ 3;
  for (int i = 0; i < cellCount; i++) {
    final int base = i * 3;
    final int latIdx = cells[base];
    final int lngIdx = cells[base + 1];
    final int val = cells[base + 2];

    // Cell 範囲 (緯度経度)
    final double south = latIdx * cellSize - 90.0;
    final double west = lngIdx * cellSize - 180.0;
    final double north = south + cellSize;
    final double east = west + cellSize;

    // Web Mercator でタイル内ピクセル座標へ変換。
    // X は経度に線形。Y は mercator の非線形変換。
    final double pxW = ((west + 180.0) / 360.0) * n * tsD - tileOriginX;
    final double pxE = ((east + 180.0) / 360.0) * n * tsD - tileOriginX;
    final double latRadS = south * pi / 180.0;
    final double latRadN = north * pi / 180.0;
    final double pyS =
        (1 - log(tan(pi / 4 + latRadS / 2)) / pi) / 2 * n * tsD - tileOriginY;
    final double pyN =
        (1 - log(tan(pi / 4 + latRadN / 2)) / pi) / 2 * n * tsD - tileOriginY;

    double left = pxW < pxE ? pxW : pxE;
    double right = pxW > pxE ? pxW : pxE;
    double top = pyN < pyS ? pyN : pyS;
    double bottom = pyN > pyS ? pyN : pyS;

    if (right <= 0 || bottom <= 0 || left >= tsD || top >= tsD) continue;

    // 隣接セル同士が 1px 隙間にならないよう floor/ceil で外側に丸める。
    int iLeft = left.floor();
    int iTop = top.floor();
    int iRight = right.ceil();
    int iBottom = bottom.ceil();
    if (iLeft < 0) iLeft = 0;
    if (iTop < 0) iTop = 0;
    if (iRight > ts) iRight = ts;
    if (iBottom > ts) iBottom = ts;
    if (iRight <= iLeft || iBottom <= iTop) continue;

    // 色計算: HSV(255→0, 1, 0.8) を val の割合で。main の
    // `_calculateCellColor` と同一式を使う (色味を揃えるため)。
    final double ratio =
        val.clamp(1, safeMax).toDouble() / safeMax.toDouble();
    final double hue = 255.0 - ratio * 255.0;
    final _Rgb rgb = _hsvToRgb(hue, 1.0, 0.8);

    // 塗りつぶし。行ごとに先頭 offset を計算し、4 バイト単位で書く。
    // Uint8List 直書きは setPixel 系より桁違いに速い。
    for (int y = iTop; y < iBottom; y++) {
      int idx = (y * ts + iLeft) * 4;
      for (int x = iLeft; x < iRight; x++) {
        buf[idx++] = rgb.r;
        buf[idx++] = rgb.g;
        buf[idx++] = rgb.b;
        buf[idx++] = 255;
      }
    }

    if (!hideStroke) {
      // 0.3 alpha 黒の枠線を 1px 分だけ塗る。掛け算 × 0.7 ≒ × 7/10 で近似。
      _strokeRect(buf, ts, iLeft, iTop, iRight, iBottom);
    }

    if (hset != null && hset.contains(_cellKey(latIdx, lngIdx))) {
      // 削除モードの赤枠 (2px)。main と同様の視覚表現。
      _strokeRectColor(buf, ts, iLeft, iTop, iRight, iBottom,
          r: 255, g: 0, b: 0, thickness: 2);
    }
  }

  // PNG エンコード。level 0 (非圧縮) で CPU 時間を最小化。
  final image = img.Image.fromBytes(
    width: ts,
    height: ts,
    bytes: buf.buffer,
    order: img.ChannelOrder.rgba,
    numChannels: 4,
  );
  // `image` パッケージは既に Uint8List を返すのでそのまま流せる。
  return img.encodePng(image, level: 0);
}

int _cellKey(int lat, int lng) {
  // z=14 基準で lat/lng は最大 2^19 程度。32bit 同士を並べて int64 キー化。
  // Dart VM の int は 64bit なのでそのまま Set<int> で O(1) 参照できる。
  return (lat & 0xFFFFFFFF) << 32 | (lng & 0xFFFFFFFF);
}

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;
}

_Rgb _hsvToRgb(double h, double s, double v) {
  // h: 0..360, s/v: 0..1
  final double c = v * s;
  final double hp = h / 60.0;
  final double x = c * (1 - ((hp % 2) - 1).abs());
  double r = 0, g = 0, b = 0;
  if (hp < 1) {
    r = c;
    g = x;
  } else if (hp < 2) {
    r = x;
    g = c;
  } else if (hp < 3) {
    g = c;
    b = x;
  } else if (hp < 4) {
    g = x;
    b = c;
  } else if (hp < 5) {
    r = x;
    b = c;
  } else {
    r = c;
    b = x;
  }
  final double m = v - c;
  final int ir = ((r + m) * 255).round().clamp(0, 255);
  final int ig = ((g + m) * 255).round().clamp(0, 255);
  final int ib = ((b + m) * 255).round().clamp(0, 255);
  return _Rgb(ir, ig, ib);
}

/// 既存塗り上に「黒 0.3 alpha」相当の 1px 枠をブレンドする。
/// 実数演算を避けて integer (×7~/10) で近似。
void _strokeRect(
    Uint8List buf, int ts, int left, int top, int right, int bottom) {
  // 上辺
  if (top >= 0 && top < ts) {
    int idx = (top * ts + left) * 4;
    for (int x = left; x < right; x++) {
      buf[idx] = (buf[idx] * 7) ~/ 10;
      buf[idx + 1] = (buf[idx + 1] * 7) ~/ 10;
      buf[idx + 2] = (buf[idx + 2] * 7) ~/ 10;
      if (buf[idx + 3] == 0) buf[idx + 3] = 76; // 透明→薄い黒
      idx += 4;
    }
  }
  // 下辺
  final int by = bottom - 1;
  if (by >= 0 && by < ts && by != top) {
    int idx = (by * ts + left) * 4;
    for (int x = left; x < right; x++) {
      buf[idx] = (buf[idx] * 7) ~/ 10;
      buf[idx + 1] = (buf[idx + 1] * 7) ~/ 10;
      buf[idx + 2] = (buf[idx + 2] * 7) ~/ 10;
      if (buf[idx + 3] == 0) buf[idx + 3] = 76;
      idx += 4;
    }
  }
  // 左辺
  if (left >= 0 && left < ts) {
    for (int y = top; y < bottom; y++) {
      final int idx = (y * ts + left) * 4;
      buf[idx] = (buf[idx] * 7) ~/ 10;
      buf[idx + 1] = (buf[idx + 1] * 7) ~/ 10;
      buf[idx + 2] = (buf[idx + 2] * 7) ~/ 10;
      if (buf[idx + 3] == 0) buf[idx + 3] = 76;
    }
  }
  // 右辺
  final int rx = right - 1;
  if (rx >= 0 && rx < ts && rx != left) {
    for (int y = top; y < bottom; y++) {
      final int idx = (y * ts + rx) * 4;
      buf[idx] = (buf[idx] * 7) ~/ 10;
      buf[idx + 1] = (buf[idx + 1] * 7) ~/ 10;
      buf[idx + 2] = (buf[idx + 2] * 7) ~/ 10;
      if (buf[idx + 3] == 0) buf[idx + 3] = 76;
    }
  }
}

/// 赤ハイライト用: 不透明色の枠線を [thickness] px 分書く。
void _strokeRectColor(
    Uint8List buf, int ts, int left, int top, int right, int bottom,
    {required int r, required int g, required int b, required int thickness}) {
  for (int t = 0; t < thickness; t++) {
    final int l = left + t;
    final int rr = right - 1 - t;
    final int tt = top + t;
    final int bb = bottom - 1 - t;
    if (l >= rr || tt >= bb) break;
    // 上下
    for (int x = l; x <= rr; x++) {
      if (tt >= 0 && tt < ts && x >= 0 && x < ts) {
        final int idx = (tt * ts + x) * 4;
        buf[idx] = r;
        buf[idx + 1] = g;
        buf[idx + 2] = b;
        buf[idx + 3] = 255;
      }
      if (bb >= 0 && bb < ts && x >= 0 && x < ts) {
        final int idx = (bb * ts + x) * 4;
        buf[idx] = r;
        buf[idx + 1] = g;
        buf[idx + 2] = b;
        buf[idx + 3] = 255;
      }
    }
    // 左右
    for (int y = tt; y <= bb; y++) {
      if (l >= 0 && l < ts && y >= 0 && y < ts) {
        final int idx = (y * ts + l) * 4;
        buf[idx] = r;
        buf[idx + 1] = g;
        buf[idx + 2] = b;
        buf[idx + 3] = 255;
      }
      if (rr >= 0 && rr < ts && y >= 0 && y < ts) {
        final int idx = (y * ts + rr) * 4;
        buf[idx] = r;
        buf[idx + 1] = g;
        buf[idx + 2] = b;
        buf[idx + 3] = 255;
      }
    }
  }
}

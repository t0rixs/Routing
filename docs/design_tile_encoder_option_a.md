# Option A: 自前ミニ PNG エンコーダ設計

## 背景

現在 Option B (Skia ネイティブ PNG) で `getTile` を実装している。
Skia の `picture.toImage()` → `toByteData(PNG)` は高速だが、
メインスレッドで `await` するため、大量タイル + 大量セルのシーンで
UI スレッドが詰まる可能性がある。

その場合は Option A に切り替える。

## 概要

`image` パッケージの `encodePng` は pure-Dart で CRC32 / Adler32 /
deflate を全て Dart 側で計算するため遅い（480×480 で 30〜100ms）。

Option A では **filter:none + deflate stored block（非圧縮）のみ** を
自前で書くことで、PNG エンコードを 5〜10 倍高速化する。
`image` パッケージへの依存も削除できる。

## PNG フォーマット概要

```
[8-byte signature]
[IHDR chunk]          — 13 bytes fixed
[IDAT chunk]          — zlib stream (header + stored blocks + adler32)
[IEND chunk]          — 0 bytes data
```

### stored block 構造（deflate non-compressed）

```
zlib header:     78 01 (deflate, level 0)
per-block:
  BFINAL (1bit) + BTYPE=00 (1bit) = 1 byte (00 or 01)
  LEN   (2 bytes LE)
  NLEN  (2 bytes LE, one's complement of LEN)
  data  (LEN bytes)
adler32:         4 bytes BE
```

### IHDR

| Field     | Size | Value                |
|-----------|------|----------------------|
| Width     | 4 BE | `ts`                 |
| Height    | 4 BE | `ts`                 |
| Bit depth | 1    | 8                    |
| Color     | 1    | 6 (RGBA)             |
| Compression | 1  | 0                    |
| Filter    | 1    | 0                    |
| Interlace | 1    | 0                    |

### フィルタ

各行の先頭に `0x00` (filter: None) を付けるだけ。
各行 = `1 + ts * 4` bytes。

## 実装

```dart
import 'dart:typed_data';

/// CRC32 lookup table (PNG chunk CRC 用)
final Uint32List _crcTable = _makeCrcTable();

Uint32List _makeCrcTable() {
  const int polynomial = 0xEDB88320;
  final table = Uint32List(256);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      if ((c & 1) != 0) {
        c = polynomial ^ (c >> 1);
      } else {
        c >>= 1;
      }
    }
    table[n] = c;
  }
  return table;
}

int _crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF);
}

/// PNG stored block の最大ペイロード (65535 bytes)。
const int _maxStoredBlock = 65535;

/// RGBA Uint8List (width×height×4) → PNG Uint8List。
/// filter:none + deflate stored block (非圧縮)。
/// `image` パッケージより 5〜10 倍高速。
Uint8List encodePngFast(Uint8List rgba, int width, int height) {
  // --- IHDR ---
  final ihdr = ByteData(13);
  ihdr.setUint32(0, width);
  ihdr.setUint32(4, height);
  ihdr.setUint8(8, 8);  // bit depth
  ihdr.setUint8(9, 6);  // color type: RGBA
  ihdr.setUint8(10, 0); // compression
  ihdr.setUint8(11, 0); // filter
  ihdr.setUint8(12, 0); // interlace

  // --- raw scanlines (filter byte 0x00 prepended per row) ---
  final int rowBytes = width * 4;
  final int rawLen = height * (1 + rowBytes);
  final Uint8List raw = Uint8List(rawLen);
  for (int y = 0; y < height; y++) {
    final int dstOff = y * (1 + rowBytes);
    raw[dstOff] = 0; // filter: None
    final int srcOff = y * rowBytes;
    raw.setRange(dstOff + 1, dstOff + 1 + rowBytes, rgba, srcOff);
  }

  // --- deflate stored blocks ---
  final int numBlocks = (rawLen + _maxStoredBlock - 1) ~/ _maxStoredBlock;
  // zlib header (2) + blocks + adler32 (4)
  int deflatedLen = 2;
  for (int i = 0; i < numBlocks; i++) {
    final int blockLen = (i < numBlocks - 1)
        ? _maxStoredBlock
        : rawLen - i * _maxStoredBlock;
    deflatedLen += 5 + blockLen; // header(5) + data
  }
  deflatedLen += 4; // adler32

  final Uint8List deflated = Uint8List(deflatedLen);
  int pos = 0;
  // zlib header
  deflated[pos++] = 0x78; // CMF
  deflated[pos++] = 0x01; // FLG (check bits for level 0)
  for (int i = 0; i < numBlocks; i++) {
    final int blockLen = (i < numBlocks - 1)
        ? _maxStoredBlock
        : rawLen - i * _maxStoredBlock;
    final bool last = (i == numBlocks - 1);
    deflated[pos++] = last ? 0x01 : 0x00; // BFINAL + BTYPE=00
    deflated[pos++] = blockLen & 0xFF;
    deflated[pos++] = (blockLen >> 8) & 0xFF;
    deflated[pos++] = ~blockLen & 0xFF;
    deflated[pos++] = (~blockLen >> 8) & 0xFF;
    deflated.setRange(pos, pos + blockLen, raw, i * _maxStoredBlock);
    pos += blockLen;
  }
  // adler32 (big-endian)
  int adler = _adler32(raw);
  deflated[pos++] = (adler >> 24) & 0xFF;
  deflated[pos++] = (adler >> 16) & 0xFF;
  deflated[pos++] = (adler >> 8) & 0xFF;
  deflated[pos++] = adler & 0xFF;

  // --- assemble PNG ---
  final int totalLen = 8 + // signature
      (12 + 13) + // IHDR
      (12 + deflatedLen) + // IDAT
      (12 + 0); // IEND
  final out = Uint8List(totalLen);
  pos = 0;

  void writeChunk(int type, Uint8List data) {
    final ByteData bd = ByteData(4);
    bd.setUint32(0, data.length);
    out.setRange(pos, pos + 4, bd.buffer.asUint8List());
    pos += 4;
    bd.setUint32(0, type);
    out.setRange(pos, pos + 4, bd.buffer.asUint8List());
    pos += 4;
    out.setRange(pos, pos + data.length, data);
    pos += data.length;
    // CRC covers type + data
    final crcInput = Uint8List(4 + data.length);
    crcInput.setRange(0, 4, bd.buffer.asUint8List());
    crcInput.setRange(4, 4 + data.length, data);
    bd.setUint32(0, _crc32(crcInput));
    out.setRange(pos, pos + 4, bd.buffer.asUint8List());
    pos += 4;
  }

  // signature
  out[pos++] = 0x89;
  out[pos++] = 0x50; out[pos++] = 0x4E; out[pos++] = 0x47;
  out[pos++] = 0x0D; out[pos++] = 0x0A; out[pos++] = 0x1A; out[pos++] = 0x0A;

  writeChunk(0x49484452, ihdr.buffer.asUint8List()); // IHDR
  writeChunk(0x49444154, deflated);                   // IDAT
  writeChunk(0x49454E44, Uint8List(0));               // IEND

  return out;
}

int _adler32(Uint8List data) {
  int a = 1, b = 0;
  const int mod = 65521;
  for (final byte in data) {
    a = (a + byte) % mod;
    b = (b + a) % mod;
  }
  return (b << 16) | a;
}
```

## Isolate での利用

Option A を採用する場合は、既存の `TileRasterizerPool` を復活させ、
`_rasterizeTile` 内の `img.encodePng(image, level: 0)` を
上記 `encodePngFast(buf, ts, ts)` に差し替えるだけでよい。

`getTile` 側は `TileRasterizerPool.instance.rasterize(...)` を呼ぶ元の形に戻す。

## 期待パフォーマンス

- `image` パッケージ `encodePng(level:0)`: 480×480 → 30〜100ms (pure Dart deflate)
- `encodePngFast`: 480×480 → 3〜10ms (memcpy + adler32 + CRC32 のみ)
- Skia ネイティブ: 480×480 → 1〜5ms (GPU アクセラレート)

## トリガー

Option B で以下のような症状が出たら切り替えを検討:

1. ズーム 14 で都市部を表示した際にドラッグが重い
   （`getTile` が `await picture.toImage()` でメインスレッドを占有）
2. `_refreshTileOverlay` 直後に数フレームのドロップが観測される
   （DevTools Performance view で確認）

## 注意点

- 生成される PNG は非圧縮なのでファイルサイズが大きい。
  タイルオーバーレイ用途（メモリ上で消費）なので実害はほぼ無い。
- CRC32 / Adler32 の計算は SIMD 無しの Dart ループなので、
  さらに高速化するなら FFI でネイティブ実装を呼ぶ選択肢もある。

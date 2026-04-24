# Routing — アプリ仕様書・アーキテクチャ解説

> 最終更新: 2026-04-23

---

## 1. アプリ概要

「Routing」は、ユーザの GPS 位置を継続的に記録し、Google Maps 上に **ヒートマップ（セル塗り）** として可視化する Flutter 製モバイルアプリ。

### 主要機能

| 機能 | 説明 |
|------|------|
| GPS 記録 | Android フォアグラウンドサービス + iOS バックグラウンド位置。1秒間隔で位置を取得し、移動経路上のセルを Zoom 3〜14 の全レベルに記録。 |
| ヒートマップ描画 | `Google Maps TileOverlay`（Android/iOS）または `flutter_map` カスタムレイヤー（デスクトップ/Web）でセルを着色描画。 |
| インポート/エクスポート | `.mapping` ファイル（ZIP + XOR 暗号化）経由でデータのバックアップ・復元。 |
| 区間削除 | 2 点のセルを選択し、その時刻範囲に含まれる Zoom 14 セルを一括削除。 |
| セルサイズ切替 | 自動モード（地図ズームに追従）と手動モード（固定 cellZ）をサポート。 |
| タイル解像度切替 | 320px / 480px / 512px から選択可能。 |
| 広告 | Google AdMob バナー（Android/iOS）。 |

---

## 2. プロジェクト構成

```
lib/
├── main.dart                          # アプリエントリ、Provider 初期化
├── models/
│   ├── cell.dart                      # Cell (lat, lng, val, tm, p1) / CellPolygon
│   └── db_key.dart                    # DBKey (z, dbLat, dbLng) — シャーディングキー
├── repositories/
│   ├── database_repository.dart       # SQLite 全操作（shard、batch、pause/resume）
│   └── file_repository.dart           # .mapping ファイルのインポート/エクスポート
├── services/
│   ├── background_activity_service.dart # バックグラウンド処理中の UI 表示制御
│   └── tile_rasterizer_pool.dart      # （現在未使用）Isolate ベースの PNG 生成
├── utils/
│   ├── cell_index.dart                # セル座標計算、DDA 線分走査
│   ├── geo_math.dart                  # 測地系計算ユーティリティ
│   ├── journal_generator.dart         # セル履歴ログジェネレータ
│   └── area3_db_generator.dart        # テスト用 DB 生成
├── viewmodels/
│   ├── map_view_model.dart            # 地図の全状態管理（GPS、描画、削除）
│   └── import_export_view_model.dart  # インポート/エクスポートの進捗管理
└── views/
    ├── home_screen.dart               # Scaffold + 地図 + ローディング + FAB
    ├── common/
    │   ├── menu_drawer.dart           # インポート/エクスポート/解像度/全削除
    │   ├── background_activity_pill.dart # 処理中表示ピル
    │   └── banner_ad_widget.dart      # AdMob バナー
    └── map/
        ├── map_widget.dart            # Google Maps 版
        ├── map_widget_adaptive.dart   # プラットフォーム切替
        ├── map_widget_flutter_map.dart # flutter_map 版（デスクトップ/Web）
        └── cell_size_control.dart     # セルサイズ設定 UI
```

---

## 3. データモデル

### 3.1 Cell（セル）

```
Cell {
  lat: int    // 緯度方向インデックス
  lng: int    // 経度方向インデックス
  val: int    // 訪問回数（ヒートマップ強度）
  tm:  int    // 最終更新時刻 (msSinceEpoch)
  p1:  int?   // 初回訪問時刻 (msSinceEpoch)
}
```

- **座標系**: `(lat, lng)` はセルインデックス空間の整数。
  - 実緯度 = `lat × cellSize - 90.0`
  - 実経度 = `lng × cellSize - 180.0`
  - `cellSize` = `0.0002 × 2^(14 - cellZ)` 度
- **Zoom 14 基準**: 1 セル ≈ 22m × 22m（赤道上）

### 3.2 DBKey（シャーディングキー）

```
DBKey(z: int, lat: int, lng: int)
```

- `z` = ズームレベル (3〜14)
- `lat` = `cellLatIndex / 1000`（整数除算）
- `lng` = `cellLngIndex / 1000`
- **ファイル名**: `hm_{z}_{lat}_{lng}.db`
- 1 shard に最大 100 万セル（1000 × 1000）

### 3.3 SQLite スキーマ

```sql
CREATE TABLE heatmap_table (
  lat INTEGER,
  lng INTEGER,
  val INTEGER,
  tm  INTEGER,
  p1  INTEGER,
  PRIMARY KEY (lat, lng)
);
CREATE INDEX idx_lat_lng ON heatmap_table (lat, lng);
```

---

## 4. アーキテクチャ

### 4.1 状態管理

```
Provider (MultiProvider)
├── MapViewModel (ChangeNotifier)        — 地図・GPS・描画の全状態
└── ImportExportViewModel (ChangeNotifier) — インポート/エクスポート進捗
```

### 4.2 GPS 記録フロー

```
Geolocator.getPositionStream (1Hz)
  → _onPositionUpdate
    → unawaited(_recordCellsForMovement(from, to))
      → CellIndex.cellsOnSegment(DDA)    // 線分が貫通する Zoom14 セルを列挙
      → DatabaseRepository.recordVisitedCells14(cells)
        → shard ごとに batch 化:
            1. (z, dbLat, dbLng) でグルーピング
            2. shard 内の既存値を SELECT で一括取得
            3. INSERT / UPDATE / DELETE を Batch に積む
            4. batch.commit(noResult: true)
      → 画面内セルなら _pendingRecordedCount += N
        → N >= 5 → _refreshTileOverlay (250ms スロットル付き)
```

### 4.3 タイル描画フロー（Option B — Skia ネイティブ）

```
Google Maps getTile(tileX, tileY, zoom)
  → DatabaseRepository.fetchCells(tileZ, cellZ, tileX, tileY)
    → shard キャッシュヒット → in-memory filter
    → キャッシュミス → SELECT
  → content hash 計算 → LRU PNG キャッシュヒット → 即返却
  → キャッシュミス:
    → ui.PictureRecorder + Canvas
    → _paintCellsOnCanvas(cells, ...)     // drawRect でセル塗り
    → picture.toImage(ts, ts)             // Skia ラスタライズ
    → image.toByteData(PNG)              // Skia ネイティブ PNG エンコード
    → LRU キャッシュに保存
    → Tile(ts, ts, pngBytes) を返す
```

### 4.4 インポートフロー

```
MenuDrawer: Import onTap
  → mapVm.setBusy(true)
    → _databaseRepository.pauseWrites()  // 書き込み停止
    → _positionSub.cancel()              // GPS ストリーム停止
    → _tileOverlay = null
  → ImportExportViewModel.importFile(path)
    → DatabaseRepository.closeAll()      // 全 DB 接続を閉じる（pauseWrites も発動）
    → FileRepository.importMappingFile()
      → 既存 .db/.sqlite を削除
      → Isolate で ZIP 展開 + XOR 復号 + DB ファイル書き出し
    → DatabaseRepository.scanExistingDatabases()
      → resumeWrites()                   // 書き込み再開
  → mapVm.setBusy(false)
    → _databaseRepository.resumeWrites() // 保険 resume
    → _refreshTileOverlay()
    → startLocationRecording()
```

### 4.5 区間削除フロー

```
onTap → Cell 情報ダイアログ → "区間削除" → startDeleteSectionMode(cellA)
  → onTap → _handleDeleteSectionSelection(cellB)
    → cellA と cellB の tm/p1 を比較 → 時刻範囲 [startT, endT] を決定
    → DatabaseRepository.fetchCellsByTimeRange(startT, endT) → 対象セルを取得
    → highlightCells にセット → _refreshTileOverlay で赤枠描画
  → "削除実行" → executeDeleteSection
    → DatabaseRepository.deleteCells(highlightCells)
      → shard ごとに batch 化 (Zoom14 削除 + Zoom3-13 減算)
```

---

## 5. 主要クラスの API

### 5.1 MapViewModel

| メソッド/プロパティ | 役割 |
|---|---|
| `setBusy(bool)` | インポート等の重処理前後で GPS・描画を一括停止/再開 |
| `startLocationRecording()` | GPS ストリーム開始（Android はフォアグラウンドサービス） |
| `disposeLocationRecording()` | GPS ストリーム停止 |
| `getTile(x, y, zoom)` | Google Maps の `TileProvider.getTile` から呼ばれる。Skia PNG 生成。 |
| `getTileImage(x, y, zoom)` | `flutter_map` 向け。`ui.Image` を直接返す。 |
| `refreshMap()` | 外部からのタイル再描画要求（スロットルバイパス） |
| `requestViewportPrefetch(bounds)` | `onCameraIdle` で呼ばれる shard プリフェッチ |
| `onTap(LatLng)` | セル情報表示 / 区間削除のエントリポイント |
| `setTileResolution(int)` | タイル解像度切替 (320/480/512) |
| `setManualCellSize(int)` / `setAutoCellSize()` | セルズームの手動/自動切替 |
| `toggleFollowUser()` | 現在地追従モードの切替 |

### 5.2 DatabaseRepository（シングルトン）

| メソッド | 役割 |
|---|---|
| `openDB(key, readOnly)` | DB を開く。キャッシュあり。書き込み中 pause 時は `readOnly:false` で `null` を返す。 |
| `closeAll()` | 全 DB を閉じる + `pauseWrites()` |
| `scanExistingDatabases()` | ファイルスキャン + `resumeWrites()` |
| `clearAllData()` | 全 DB ファイル削除 + `resumeWrites()` |
| `pauseWrites()` / `resumeWrites()` | 書き込みの一時停止/再開 |
| `fetchCells(tileZ, cellZ, x, y)` | タイル範囲のセルを取得（shard キャッシュ活用） |
| `prefetchShards(cellZ, sLat, nLat, wLng, eLng)` | viewport 内の全 shard を先読みキャッシュ |
| `recordVisitedCells14(cells)` | Zoom14 セル + 親ズームを shard batch で記録 |
| `deleteCells(cells)` | セル一括削除（shard batch） |
| `getCell(cellZ, lat, lng)` | 単一セル取得 |
| `fetchCellsByTimeRange(start, end)` | 時間範囲による Zoom14 セル検索 |

### 5.3 FileRepository

| メソッド | 役割 |
|---|---|
| `importMappingFile(path, dbBasePath)` | Isolate で ZIP 展開 + XOR 復号 + DB 書き出し |
| `exportMappingFile(dbBasePath)` | 既存 DB を ZIP + XOR 暗号化して共有 |

---

## 6. パフォーマンス関連の設計

### 6.1 タイル描画（Skia ネイティブ PNG）

- **方式**: `ui.PictureRecorder` → `Canvas` → `picture.toImage()` → `toByteData(PNG)`
- **特徴**: Skia のネイティブ PNG エンコーダを使用。pure-Dart の `image` パッケージ比で 5〜10 倍高速。
- **LRU PNG キャッシュ**: 最大 256 エントリ。content hash で同一内容タイルを即返却。
- **shard プリフェッチ**: `onCameraIdle` で viewport 内の全 shard を先読み。`getTile` での DB アクセスを回避。

### 6.2 DB 書き込みのバッチ化

- GPS 記録時、セルごとに 12 ズームレベルの書き込みを **shard ごとに 1 バッチ** に集約。
- shard 内の既存値を 1 回の `SELECT` で取得し、`INSERT/UPDATE/DELETE` を `db.batch()` に積んで `commit(noResult: true)`。
- プラットフォームチャネル往復が「セル数 × 12」→「ユニーク shard 数（通常 1〜3）」に圧縮。

### 6.3 _refreshTileOverlay のスロットル

- GPS 記録中の連続 `TileOverlay` 再生成を **250ms 間隔** に制限。
- `refreshMap()` はスロットルをバイパス（ユーザの明示的操作用）。

### 6.4 ジェスチャ中の最適化

- `_isGesturing` フラグでドラッグ/ピンチ中の `_refreshTileOverlay` を `onCameraIdle` まで延期。
- Google Maps のタイルキャッシュ破棄（`TileOverlayId` 変更）を最小回数に抑える。

---

## 7. 書き込み Pause 機構（インポート時のレース条件対策）

### 問題

`unawaited(_recordCellsForMovement(...))` で起動された future が、`setBusy(true)` 後も実行を継続し、`closeAll()` でキャッシュがクリアされた状態で `openDB(readOnly:false)` を呼ぶ。結果として：

1. 新しい空 DB ファイルが作成される（インポート Isolate と inode 衝突）
2. `SQLITE_READONLY_DBMOVED` エラーが大量発生
3. `debugPrint` がメインスレッドのログ I/O を飽和させ、インポートが 2 分遅延

### 解決策

```
_writesPaused: bool = false

pauseWrites()  → _writesPaused = true
resumeWrites() → _writesPaused = false

・openDB(key, readOnly:false) → _writesPaused 時は null を返す
・recordVisitedCells14 / deleteCells → 先頭で if (_writesPaused) return
・closeAll() → 自動で pauseWrites() を呼ぶ
・scanExistingDatabases() / clearAllData() → 末尾で resumeWrites() を呼ぶ
・setBusy(true) → _positionSub.cancel() の前に pauseWrites()
・setBusy(false) → resumeWrites() + GPS 再開
```

---

## 8. プラットフォーム対応

| プラットフォーム | 地図エンジン | DB エンジン | 備考 |
|---|---|---|---|
| Android | `google_maps_flutter` | `sqflite` | フォアグラウンドサービスでバックグラウンド GPS |
| iOS | `google_maps_flutter` | `sqflite` | バックグラウンド位置（要設定） |
| macOS | `flutter_map` | `sqflite_common_ffi` | デスクトップ開発・テスト用 |
| Linux | `flutter_map` | `sqflite_common_ffi` | 同上 |
| Windows | `flutter_map` | `sqflite_common_ffi` | 同上 |
| Web | `flutter_map` | (未対応) | セルサイズ制御のみ |

---

## 9. 外部依存パッケージ

| パッケージ | 用途 |
|---|---|
| `google_maps_flutter` | Android/iOS の Google Maps 表示 |
| `flutter_map` + `latlong2` | デスクトップ/Web の地図表示 |
| `sqflite` | SQLite データベース（モバイル） |
| `sqflite_common_ffi` | SQLite データベース（デスクトップ） |
| `geolocator` | GPS 位置取得 |
| `provider` | 状態管理 |
| `file_picker` | インポートファイル選択 |
| `archive` | ZIP 圧縮/展開 |
| `shared_preferences` | カメラ位置の永続化 |
| `permission_handler` | Android 通知権限等 |
| `google_mobile_ads` | AdMob 広告 |
| `share_plus` | エクスポートファイルの共有 |
| `image` | （現未使用）PNG エンコード用 |
| `intl` | 日付フォーマット |

---

## 10. 今後の改善候補

### 10.1 Option A: 自前ミニ PNG エンコーダ

- 詳細は `docs/design_tile_encoder_option_a.md` を参照。
- Option B（Skia ネイティブ）でメインスレッドが詰まる場合の备用。
- `image` パッケージの pure-Dart `encodePng` より 5〜10 倍高速なエンコーダを自前実装。
- Isolate で並列実行する `TileRasterizerPool` を復活させて使用。

### 10.2 その他の改善点

- **GPS 更新のスロットル**: `distanceFilter: 0` で 1Hz だが、高密度都市部では `unawaited` future が大量に積まる可能性。`_recordCellsForMovement` の直列化（`Completer` チェーン等）を検討。
- **shard キャッシュのLRU化**: 現在は無制限に保持。メモリ圧迫の恐れがある場合は上限を設ける。
- **WAL モード**: SQLite の WAL モードを明示的に有効化すると、読み書きの並行性が向上する可能性。

---

## 11. 参考プロジェクト: Routepia

- **パス**: `/Users/myash/Documents/Programing/02_Projects/Routepia`
- **関係**: 同じヒートマップ概念の別実装。cell 数が膨大でも指に張り付くように動作する。
- **主な違い**:
  - DB 操作に `_databaseOperationLock`（`synchronized` パッケージ）で排他制御。
  - `insertCells` で `db.batch()` を使用（Routing に取り込み済み）。
  - `getTile` も Skia ネイティブ方式（`picture.toImage + toByteData(PNG)`）。
  - `TileOverlayProvider` は `notifyListeners()` のみで `tileOverlayId` を変える。

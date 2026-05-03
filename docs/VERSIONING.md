# バージョン管理ルール

本プロジェクトは **SemVer (Semantic Versioning) ベース** + **Android `versionCode` の単調増加** を組み合わせて運用する。

`pubspec.yaml` の表記:

```yaml
version: MAJOR.MINOR.PATCH+versionCode
```

- 前半 `MAJOR.MINOR.PATCH` がバージョンネーム（ユーザー向け / `flutter.versionName`）。
- 後半 `versionCode` は Android の `flutter.versionCode`（Play Console アップロード時の単調増加整数）。

`android/local.properties` の `flutter.versionCode` も同じ値を保持し、両者を必ず同期させる。

---

## バージョンネーム（MAJOR.MINOR.PATCH）

| 要素 | 上げる条件 | 例 |
|---|---|---|
| **MAJOR** | DB スキーマや `.mapping` 形式の **非互換変更**、UX の大規模刷新（旧フローが使えなくなる）、有料化など事業上の大変更 | 1.0.0 → 2.0.0 |
| **MINOR** | 新機能追加、既存機能の大幅改善、設定項目の追加（互換性維持） | 0.1.x → 0.2.0 |
| **PATCH** | バグ修正、小さな最適化、UI 微調整、文言修正、依存関係更新（挙動に影響なし） | 0.1.0 → 0.1.1 |

ベータ期間中（MAJOR=0）は API 互換が保証されないので、MINOR を新機能、PATCH を修正に充てて柔軟に運用する。

---

## versionCode

- **リリース毎に +1**。スキップは可（ローカルビルドや内部テストで余分に進んでも問題ない）。
- **絶対に下げない／同じ値で再アップロードしない**。Play Console は同一 versionCode を拒否する。
- バージョンネームを変えなくても versionCode だけ進める運用は OK（同一バージョンの再ビルドなど）。

---

## 運用フロー

1. 変更内容を確認し、適切な MAJOR/MINOR/PATCH を決定する。
2. `pubspec.yaml` の `version:` を `M.m.p+N` の形で更新。
3. `android/local.properties` の `flutter.versionCode` を `N` に同期。
4. `flutter build appbundle --release` でビルドし、`app-release.aab` を Play Console にアップロード。
5. 本ファイル下部「履歴」に 1 行で変更概要を追記する。

---

## 履歴

| Version | versionCode | 主な変更 |
|---|---|---|
| 0.0.1 | 1〜6 | 初期リリース系。基本機能（記録・地図・タイル描画・Import/Export） |
| 0.1.0 | 7 | UI リニューアル（円弧 FAB メニュー、ダークモード、StatsHud、AppBar 削除）、コンパス無効化、追従ロック |
| 0.1.1 | 8 | バッテリー最適化（GPS 間隔 1s→3s、distanceFilter 5m）、達成度長押し、HSV V=1.0 |
| 0.1.2 | 9 | BG 中は DB 書き込みのみに限定（タイル再生成・stats集計・notifyListeners をスキップ）。GPS 間隔は 1s に戻し |
| 0.1.3 | 10 | バナー広告クリック後 5 分間サスペンド機能（SharedPreferences で永続化）。ダークモード × 地図ベーススタイル不整合バグ修正（cycleMapBaseStyle がテーマ追従、起動時に保存テーマと地図を同期） |
| 0.1.4 | 11 | セル色ランプ刷新。RGB lerp で鈍っていた v=1, v=2 を HSV 直接指定に変更し、深く鮮やかな青に（v=1: HSV(255°,0.85,0.40) / v=2: HSV(255°,0.95,0.65) / v=3: 純粋な青）。マーカー・PNG タイル両系統で計算式を統一 |
| 0.1.5 | 12 | バナー広告ユニット ID を home_bottom_banner（…/1839413049）へ変更。クリック後サスペンド期間を 5 分→10 分に延長。Google Play In-App Updates（Flexible フロー）導入：起動時に Play Store の最新版を確認し、新版があればバックグラウンドダウンロード→SnackBar で再起動を促す。サーバ不要 |

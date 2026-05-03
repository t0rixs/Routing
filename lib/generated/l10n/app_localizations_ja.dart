// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'Routepia';

  @override
  String get yes => 'はい';

  @override
  String get no => 'いいえ';

  @override
  String get ok => 'OK';

  @override
  String get cancel => 'キャンセル';

  @override
  String get save => '保存';

  @override
  String get delete => '削除';

  @override
  String get execute => '実行';

  @override
  String get later => 'あとで';

  @override
  String get openSettings => '設定を開く';

  @override
  String get loading => '読み込み中...';

  @override
  String get extractingFiles => 'ファイルを展開中...';

  @override
  String get you => 'あなた';

  @override
  String get complete => 'Complete.';

  @override
  String get menuRecordLocation => '位置情報を記録';

  @override
  String get menuRecording => '記録中（タップで停止）';

  @override
  String get menuStopped => '停止中（タップで再開）';

  @override
  String get menuTileResolution => 'タイル解像度';

  @override
  String get menuDarkMode => 'ダークモード';

  @override
  String get menuDarkModeOn => 'ダーク（UI＋マップ）';

  @override
  String get menuDarkModeOff => 'ライト（UI＋マップ）';

  @override
  String get menuMapStyleSettings => 'マップ表示の詳細設定';

  @override
  String get menuMapStyleSettingsSubtitle => 'ランドマーク・駅・路線などを個別に切替';

  @override
  String get menuLanguage => '言語';

  @override
  String get menuLanguageSystem => 'システム設定に従う';

  @override
  String get menuRebuildLowZoom => '低ズーム描画を再構築';

  @override
  String get menuRebuildLowZoomBody => '完了まで数十秒〜数分かかる場合があります。';

  @override
  String get menuRebuildInProgress => '再構築中...';

  @override
  String menuRebuildShards(int processed, int total) {
    return '$processed / $total shards';
  }

  @override
  String get menuRebuildScanning => 'z=14 shard を走査中...';

  @override
  String get menuRebuildSuccess => '低ズーム描画の再構築が完了しました';

  @override
  String menuRebuildFailed(String error) {
    return '再構築に失敗: $error';
  }

  @override
  String get menuClearAll => '全記録をクリア';

  @override
  String get menuClearAllSubtitle => 'すべての DB を削除します';

  @override
  String get menuClearAllConfirmBody =>
      '記録済みのデータを全て削除します。この操作は取り消せません。よろしいですか？';

  @override
  String get menuClearAllDone => '全ての記録を削除しました';

  @override
  String menuClearAllFailed(String error) {
    return '削除失敗: $error';
  }

  @override
  String get tileResLow => '低 (320px)';

  @override
  String get tileResMid => '中 (480px)';

  @override
  String get tileResHigh => '高 (512px)';

  @override
  String get mapSettingsTitle => 'マップ表示の詳細設定';

  @override
  String get mapSettingsReset => 'リセット';

  @override
  String get mapSectionPoi => 'ランドマーク（POI）';

  @override
  String get mapSectionTransit => '交通機関';

  @override
  String get mapSectionLabels => 'ラベル';

  @override
  String get poiBusiness => '店舗・商業施設';

  @override
  String get poiPark => '公園';

  @override
  String get poiAttraction => '観光地';

  @override
  String get poiGovernment => '官公庁';

  @override
  String get poiMedical => '病院・医療';

  @override
  String get poiSchool => '学校';

  @override
  String get poiPlaceOfWorship => '宗教施設';

  @override
  String get poiSportsComplex => '運動施設';

  @override
  String get transitLine => '路線（鉄道・バス等の線）';

  @override
  String get railwayStation => '鉄道駅';

  @override
  String get busStation => 'バス停';

  @override
  String get airport => '空港';

  @override
  String get labelRoad => '道路ラベル';

  @override
  String get labelAdmin => '地名・境界ラベル';

  @override
  String get dateFilterHelp => '日付で絞り込み';

  @override
  String get dateFilterApply => '適用';

  @override
  String get locationRationaleTitle => '位置情報の利用について';

  @override
  String get locationRationaleBody1 =>
      'このアプリはローカルに移動ログを保存するため、バックグラウンドで位置情報を使用します。';

  @override
  String get locationRationaleBody2 => '取得した位置情報はあなたの端末内にのみ保存され、サーバには送信されません。';

  @override
  String get locationRationaleBody3 =>
      '次に OS の許可ダイアログが表示されます。バックグラウンドでも記録するためには「常に許可」を選択してください。';

  @override
  String get locationAlwaysTitle => '位置情報を「常に許可」に設定してください';

  @override
  String get locationAlwaysBody =>
      'このアプリは、アプリを閉じている間も走行ルートを記録するために、位置情報の「常に許可」が必要です。\n\n設定画面の「位置情報」を開き、「常に」を選択してください。';

  @override
  String get notificationRecordingText => '移動履歴を記録中...';

  @override
  String get tooltipFollowingOn => '追従中（タップで解除）';

  @override
  String get tooltipFollowingOff => '現在地に追従';

  @override
  String get tooltipMenu => '設定 / メニュー';

  @override
  String get tooltipMapSatellite => '衛星マップ（タップで白紙に切替）';

  @override
  String get tooltipMapBlank => '白紙マップ（タップで通常に切替）';

  @override
  String get tooltipMapStandard => '通常マップ（タップで衛星に切替）';

  @override
  String get tooltipResetCamera => '北向き・水平に戻す';

  @override
  String get fabClose => '閉じる（長押しで達成度）';

  @override
  String get fabMenu => 'メニュー（長押しで達成度）';

  @override
  String cellInfoFirst(String date) {
    return '初回更新: $date';
  }

  @override
  String cellInfoLast(String date) {
    return '最終更新時間: $date';
  }

  @override
  String get deleteSection => '区間削除';

  @override
  String get deleteSectionConfirmTitle => '区間削除';

  @override
  String deleteSectionConfirmBody(int count) {
    return '選択された範囲のデータを削除しますか？\nこの操作は取り消せません。\n対象セル数: $count';
  }

  @override
  String get deleteSelected => '削除範囲が選択されました';

  @override
  String get deleteSelectEnd => '区間の終点を選択してください';

  @override
  String deleteExecuteCells(int count) {
    return '削除実行 ($count cells)';
  }

  @override
  String get deleteRunningTitle => '削除実行中';

  @override
  String get deleteDoneTitle => '削除完了';

  @override
  String get deleteDoneBody => '区間の削除が完了しました。';

  @override
  String get cellSizeFix => '現在の拡大率でセルサイズを固定';

  @override
  String get statsTitle => '累計データ';

  @override
  String get statsTabAchievement => '達成度';

  @override
  String get statsTabHistory => '履歴';

  @override
  String statsLoadFailed(String error) {
    return '読み込み失敗: $error';
  }

  @override
  String get statsHistoryEmpty => 'まだ履歴がありません。\n歩いて記録しましょう。';

  @override
  String get statsTitleLabel => 'タイトル';

  @override
  String get statsTitleHint => '最大 16 文字';

  @override
  String get statsCellNew => '新規';

  @override
  String get statsCellExisting => '既存';

  @override
  String saveFailed(String error) {
    return '保存失敗: $error';
  }

  @override
  String areaUnitM2(String value) {
    return '$value m²';
  }

  @override
  String areaUnitKm2(String value) {
    return '$value km²';
  }

  @override
  String get updateAvailableTitle => 'アップデートがあります';

  @override
  String get updateAvailableBody => '新しいバージョンが公開されました。今すぐ更新しますか？';

  @override
  String get updateLater => 'あとで';

  @override
  String get updateNow => '更新';

  @override
  String get continueAction => 'OK（続ける）';

  @override
  String cellSizeLockedTooltip(int z) {
    return 'Z$z（タップで自動に戻す）';
  }

  @override
  String get menuRebuildSubtitle => 'z=14 の記録から z=3..13 を作り直します';
}

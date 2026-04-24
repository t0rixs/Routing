/// 達成度タブで「あなたの踏破面積を世界の地物と比較する」ために使う
/// 参考データセット。面積は **平方キロメートル (km²)** で保持する。
///
/// 出典: Wikipedia 各記事（2024 年時点の概算値）。
/// 順序は面積昇順で並べているため、ユーザの踏破面積を二分探索で
/// 「どの間にあるか」判定しやすい。
library;

class WorldArea {
  const WorldArea(this.name, this.areaKm2, {this.kind = 'country'});
  final String name;

  /// 面積 (km²)
  final double areaKm2;

  /// 'country' | 'region' | 'landmark' | 'island' | 'natural'
  /// UI で絵文字やアイコンを切替えるためのカテゴリ。
  final String kind;
}

/// 面積昇順にソート済み。**末尾に追加するときも昇順を保つこと**。
const List<WorldArea> kWorldAreas = <WorldArea>[
  // ランドマーク
  WorldArea('東京ドーム', 0.047, kind: 'landmark'),
  WorldArea('東京ディズニーランド', 0.51, kind: 'landmark'),
  WorldArea('東京ディズニーリゾート全域', 2.01, kind: 'landmark'),
  WorldArea('皇居', 1.15, kind: 'landmark'),
  WorldArea('セントラルパーク', 3.41, kind: 'landmark'),

  // 微小国家・島
  WorldArea('バチカン市国', 0.49, kind: 'country'),
  WorldArea('ジブラルタル', 6.7, kind: 'region'),
  WorldArea('モナコ', 2.02, kind: 'country'),
  WorldArea('ナウル', 21, kind: 'country'),
  WorldArea('ツバル', 26, kind: 'country'),
  WorldArea('サンマリノ', 61, kind: 'country'),
  WorldArea('リヒテンシュタイン', 160, kind: 'country'),
  WorldArea('マーシャル諸島', 181, kind: 'country'),
  WorldArea('セントクリストファー・ネイビス', 261, kind: 'country'),
  WorldArea('モルディブ', 298, kind: 'country'),
  WorldArea('マルタ', 316, kind: 'country'),
  WorldArea('グレナダ', 344, kind: 'country'),
  WorldArea('セントビンセント・グレナディーン', 389, kind: 'country'),
  WorldArea('バルバドス', 430, kind: 'country'),
  WorldArea('アンティグア・バーブーダ', 442, kind: 'country'),
  WorldArea('セーシェル', 459, kind: 'country'),
  WorldArea('パラオ', 459, kind: 'country'),
  WorldArea('アンドラ', 468, kind: 'country'),

  // 都市・地域
  WorldArea('山手線内側', 63, kind: 'region'),
  WorldArea('東京 23 区', 628, kind: 'region'),
  WorldArea('シンガポール', 728, kind: 'country'),
  WorldArea('香港', 1106, kind: 'region'),
  WorldArea('沖縄本島', 1207, kind: 'island'),
  WorldArea('大阪府', 1905, kind: 'region'),
  WorldArea('東京都', 2194, kind: 'region'),
  WorldArea('ルクセンブルク', 2586, kind: 'country'),

  // 中規模
  WorldArea('佐渡島', 855, kind: 'island'),
  WorldArea('種子島', 444, kind: 'island'),
  WorldArea('屋久島', 504, kind: 'island'),
  WorldArea('淡路島', 592, kind: 'island'),
  WorldArea('対馬', 696, kind: 'island'),
  WorldArea('天草下島', 575, kind: 'island'),
  WorldArea('神奈川県', 2416, kind: 'region'),
  WorldArea('千葉県', 5158, kind: 'region'),
  WorldArea('埼玉県', 3798, kind: 'region'),
  WorldArea('愛知県', 5173, kind: 'region'),

  // 大規模
  WorldArea('福岡県', 4987, kind: 'region'),
  WorldArea('京都府', 4612, kind: 'region'),
  WorldArea('北海道', 78421, kind: 'region'),
  WorldArea('四国', 18803, kind: 'island'),
  WorldArea('九州', 36782, kind: 'island'),
  WorldArea('本州', 227943, kind: 'island'),

  // 国
  WorldArea('スイス', 41285, kind: 'country'),
  WorldArea('オランダ', 41850, kind: 'country'),
  WorldArea('デンマーク', 43094, kind: 'country'),
  WorldArea('韓国', 100210, kind: 'country'),
  WorldArea('台湾', 36193, kind: 'country'),
  WorldArea('イギリス', 243610, kind: 'country'),
  WorldArea('ニュージーランド', 268021, kind: 'country'),
  WorldArea('イタリア', 301340, kind: 'country'),
  WorldArea('ドイツ', 357022, kind: 'country'),
  WorldArea('日本', 377975, kind: 'country'),
  WorldArea('スウェーデン', 450295, kind: 'country'),
  WorldArea('スペイン', 505990, kind: 'country'),
  WorldArea('フランス', 643801, kind: 'country'),
  WorldArea('テキサス州', 695662, kind: 'region'),
  WorldArea('トルコ', 783356, kind: 'country'),
  WorldArea('メキシコ', 1964375, kind: 'country'),
  WorldArea('インドネシア', 1904569, kind: 'country'),
  WorldArea('インド', 3287263, kind: 'country'),
  WorldArea('オーストラリア', 7692024, kind: 'country'),
  WorldArea('ブラジル', 8515767, kind: 'country'),
  WorldArea('アメリカ合衆国', 9833520, kind: 'country'),
  WorldArea('カナダ', 9984670, kind: 'country'),
  WorldArea('中国', 9596961, kind: 'country'),
  WorldArea('ロシア', 17098246, kind: 'country'),

  // 自然
  WorldArea('月の表面', 37930000, kind: 'natural'),
  WorldArea('地球の陸地', 148940000, kind: 'natural'),
];

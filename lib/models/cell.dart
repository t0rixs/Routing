/// マッピングデータの最小単位（セル）を表現するクラス
class Cell {
  final int lat;
  final int lng;
  final int val;
  final int tm;
  final int? p1;

  const Cell({
    required this.lat,
    required this.lng,
    required this.val,
    required this.tm,
    this.p1,
  });

  /// SQLiteの検索結果(Map)からCellインスタンスを生成
  factory Cell.fromSqlite(Map<String, dynamic> data) {
    return Cell(
      lat: data['lat'] as int,
      lng: data['lng'] as int,
      val: data['val'] as int,
      tm: data['tm'] as int,
      // p1はnull許容
      p1: data['p1'] as int?,
    );
  }

  /// Map形式に変換（デバッグ出力等用）
  Map<String, dynamic> toMap() {
    return {
      'lat': lat,
      'lng': lng,
      'val': val,
      'tm': tm,
      'p1': p1,
    };
  }

  @override
  String toString() => 'Cell(lat: $lat, lng: $lng, val: $val)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cell &&
          runtimeType == other.runtimeType &&
          lat == other.lat &&
          lng == other.lng;

  @override
  int get hashCode => lat.hashCode ^ lng.hashCode;
}

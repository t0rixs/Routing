/// データベースファイルのシャーディングキー（Zoomレベル、DB経度、DB緯度）
class DBKey {
  final int z;
  final int lat;
  final int lng;

  const DBKey(this.z, this.lat, this.lng);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DBKey &&
          runtimeType == other.runtimeType &&
          z == other.z &&
          lat == other.lat &&
          lng == other.lng;

  @override
  int get hashCode => z.hashCode ^ lat.hashCode ^ lng.hashCode;

  @override
  String toString() => '${z}_${lat}_${lng}';

  /// ファイル名 (hm_{z}_{lat}_{lng}.db) を生成
  String toFileName() => 'hm_${z}_${lat}_${lng}.db';
}

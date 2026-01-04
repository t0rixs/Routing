import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:convert';

Future<String> cameraPositiontoString(CameraPosition cameraPosition) async {
  return jsonEncode({
    'target': {
      'latitude': cameraPosition.target.latitude,
      'longitude': cameraPosition.target.longitude,
    },
    'zoom': cameraPosition.zoom,
    'tilt': cameraPosition.tilt,
    'bearing': cameraPosition.bearing,
  });
}

Future<CameraPosition> stringtoCameraPosition(String string) async {
  final json = jsonDecode(string);
  return CameraPosition(
    target: LatLng(json['target']['latitude'], json['target']['longitude']),
    zoom: json['zoom'],
    tilt: json['tilt'],
    bearing: json['bearing'],
  );
}

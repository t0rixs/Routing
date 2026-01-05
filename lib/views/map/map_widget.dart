import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../../viewmodels/map_view_model.dart';
import 'package:intl/intl.dart';

class MapWidget extends StatelessWidget {
  const MapWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, viewModel, child) {
        return GoogleMap(
          initialCameraPosition: viewModel.cameraPosition,
          onMapCreated: viewModel.onMapCreated,
          onCameraMove: viewModel.onCameraMove,
          onTap: (latLng) async {
            // タップしたセルの情報を取得
            final cell = await viewModel.onTap(latLng);
            if (context.mounted && cell != null) {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Cell Info'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Value: ${cell.val}'),
                      Text('Lat Index: ${cell.lat}'),
                      Text('Lng Index: ${cell.lng}'),
                      if (cell.p1 != null && cell.p1! > 0)
                        Text(
                            '初回更新: ${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(cell.p1!))}'),
                      Text(
                          '最終更新時間: ${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(cell.tm))}'),
                    ],
                  ),
                  actions: [
                    TextButton(
                      child: const Text('Close'),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              );
            }
          },
          tileOverlays:
              viewModel.tileOverlay != null ? {viewModel.tileOverlay!} : {},
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          compassEnabled: true,
          mapToolbarEnabled: false,
        );
      },
    );
  }
}

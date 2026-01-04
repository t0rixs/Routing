import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../../viewmodels/map_view_model.dart';

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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../generated/l10n/app_localizations.dart';
import '../../viewmodels/map_view_model.dart';
import 'banner_ad_widget.dart';

/// マップに表示する各要素（ランドマーク種別・交通機関・ラベル等）を
/// 個別にオン／オフする設定画面。
///
/// ライト／ダーク（ベーステーマ）はメニュー側で選択する前提。
class MapStyleSettingsScreen extends StatelessWidget {
  const MapStyleSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.mapSettingsTitle),
        actions: [
          Consumer<MapViewModel>(
            builder: (context, vm, _) {
              return TextButton(
                onPressed: () =>
                    vm.setStyleOverrides(const MapStyleOverrides()),
                child: Text(
                  l.mapSettingsReset,
                  style: const TextStyle(color: Colors.white),
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<MapViewModel>(
        builder: (context, vm, _) {
          final o = vm.styleOverrides;
          return ListView(
            children: [
              _SectionHeader(title: l.mapSectionPoi),
              _SwitchTile(
                title: l.poiBusiness,
                value: o.showPoiBusiness,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiBusiness: v)),
              ),
              _SwitchTile(
                title: l.poiPark,
                value: o.showPoiPark,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showPoiPark: v)),
              ),
              _SwitchTile(
                title: l.poiAttraction,
                value: o.showPoiAttraction,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiAttraction: v)),
              ),
              _SwitchTile(
                title: l.poiGovernment,
                value: o.showPoiGovernment,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiGovernment: v)),
              ),
              _SwitchTile(
                title: l.poiMedical,
                value: o.showPoiMedical,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showPoiMedical: v)),
              ),
              _SwitchTile(
                title: l.poiSchool,
                value: o.showPoiSchool,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showPoiSchool: v)),
              ),
              _SwitchTile(
                title: l.poiPlaceOfWorship,
                value: o.showPoiPlaceOfWorship,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiPlaceOfWorship: v)),
              ),
              _SwitchTile(
                title: l.poiSportsComplex,
                value: o.showPoiSportsComplex,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiSportsComplex: v)),
              ),
              const Divider(),
              _SectionHeader(title: l.mapSectionTransit),
              _SwitchTile(
                title: l.transitLine,
                value: o.showTransitLine,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showTransitLine: v)),
              ),
              _SwitchTile(
                title: l.railwayStation,
                value: o.showRailwayStation,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showRailwayStation: v)),
              ),
              _SwitchTile(
                title: l.busStation,
                value: o.showBusStation,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showBusStation: v)),
              ),
              _SwitchTile(
                title: l.airport,
                value: o.showAirport,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showAirport: v)),
              ),
              const Divider(),
              _SectionHeader(title: l.mapSectionLabels),
              _SwitchTile(
                title: l.labelRoad,
                value: o.showRoadLabels,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showRoadLabels: v)),
              ),
              _SwitchTile(
                title: l.labelAdmin,
                value: o.showAdminLabels,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showAdminLabels: v)),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
      bottomNavigationBar: const SafeArea(
        top: false,
        child: BannerAdWidget(),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }
}

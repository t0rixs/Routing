import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('マップ表示の詳細設定'),
        actions: [
          Consumer<MapViewModel>(
            builder: (context, vm, _) {
              return TextButton(
                onPressed: () =>
                    vm.setStyleOverrides(const MapStyleOverrides()),
                child: const Text(
                  'リセット',
                  style: TextStyle(color: Colors.white),
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
              _SectionHeader(title: 'ランドマーク（POI）'),
              _SwitchTile(
                title: '店舗・商業施設',
                value: o.showPoiBusiness,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiBusiness: v)),
              ),
              _SwitchTile(
                title: '公園',
                value: o.showPoiPark,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showPoiPark: v)),
              ),
              _SwitchTile(
                title: '観光地',
                value: o.showPoiAttraction,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiAttraction: v)),
              ),
              _SwitchTile(
                title: '官公庁',
                value: o.showPoiGovernment,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiGovernment: v)),
              ),
              _SwitchTile(
                title: '病院・医療',
                value: o.showPoiMedical,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showPoiMedical: v)),
              ),
              _SwitchTile(
                title: '学校',
                value: o.showPoiSchool,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showPoiSchool: v)),
              ),
              _SwitchTile(
                title: '宗教施設',
                value: o.showPoiPlaceOfWorship,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiPlaceOfWorship: v)),
              ),
              _SwitchTile(
                title: '運動施設',
                value: o.showPoiSportsComplex,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showPoiSportsComplex: v)),
              ),
              const Divider(),
              _SectionHeader(title: '交通機関'),
              _SwitchTile(
                title: '路線（鉄道・バス等の線）',
                value: o.showTransitLine,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showTransitLine: v)),
              ),
              _SwitchTile(
                title: '鉄道駅',
                value: o.showRailwayStation,
                onChanged: (v) => vm.setStyleOverrides(
                    o.copyWith(showRailwayStation: v)),
              ),
              _SwitchTile(
                title: 'バス停',
                value: o.showBusStation,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showBusStation: v)),
              ),
              _SwitchTile(
                title: '空港',
                value: o.showAirport,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showAirport: v)),
              ),
              const Divider(),
              _SectionHeader(title: 'ラベル'),
              _SwitchTile(
                title: '道路ラベル',
                value: o.showRoadLabels,
                onChanged: (v) =>
                    vm.setStyleOverrides(o.copyWith(showRoadLabels: v)),
              ),
              _SwitchTile(
                title: '地名・境界ラベル',
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

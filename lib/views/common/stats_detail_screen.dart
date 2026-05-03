import 'dart:io';

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/world_areas.dart';
import '../../generated/l10n/app_localizations.dart';
import '../../repositories/database_repository.dart';
import '../../viewmodels/map_view_model.dart';
import 'banner_ad_widget.dart';

/// 1 セルの面積（m2）。仕様で 314.8553 m2 だが、表示は m2 単位の整数として
/// 扱う（小数点以下は捨象）。
const int kCellAreaM2 = 315;

/// HUD タップから開く累計データ詳細画面。
///
/// - **達成度**: 重複なしセル数 × `kCellAreaM2` で総面積を算出し、
///   `kWorldAreas` の各地物面積と比較する。
/// - **履歴**: `area3.sqlite / area_table` と `title.sqlite / title_table` を
///   `appDatabasesPath()` 配下から読み、日付降順で 1 行ずつ表示する。
class StatsDetailScreen extends StatelessWidget {
  const StatsDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final l = AppLocalizations.of(context)!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: isDark ? Colors.black : null,
        appBar: AppBar(
          title: Text(l.statsTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: l.statsTabAchievement, icon: const Icon(Icons.emoji_events)),
              Tab(text: l.statsTabHistory, icon: const Icon(Icons.calendar_today)),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _AchievementTab(),
            _HistoryTab(),
          ],
        ),
        bottomNavigationBar: const SafeArea(
          top: false,
          child: BannerAdWidget(),
        ),
      ),
    );
  }
}

// ===========================================================================
// 達成度タブ
// ===========================================================================

/// 達成度タブ。`kWorldAreas` とユーザー自身の総踏破面積（重複なしセル × 315m2）を
/// 大きい順に並べた単一のランキングリストを表示する。ユーザー行（"あなた"）は
/// その面積に応じた正しい順位に挿入され、初期表示時に画面中央に自動スクロールする。
/// ユーザーより小さい（ランクが下）地物は「Complete.」表記になる。
class _AchievementTab extends StatefulWidget {
  const _AchievementTab();

  @override
  State<_AchievementTab> createState() => _AchievementTabState();
}

class _AchievementTabState extends State<_AchievementTab> {
  final ScrollController _scrollCtl = ScrollController();
  // 各行のアイテム高さ（概算）。下からの scroll offset 計算に使う。
  static const double _kItemHeight = 92.0;
  int _userIndex = 0;
  bool _initialScrollDone = false;

  @override
  void dispose() {
    _scrollCtl.dispose();
    super.dispose();
  }

  void _scheduleScrollToUser() {
    if (_initialScrollDone) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtl.hasClients) return;
      final double target = (_userIndex * _kItemHeight) -
          (MediaQuery.of(context).size.height / 3);
      final double max = _scrollCtl.position.maxScrollExtent;
      _scrollCtl.jumpTo(target.clamp(0.0, max));
      _initialScrollDone = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final String lang = Localizations.localeOf(context).languageCode;
    return Consumer<MapViewModel>(
      builder: (context, vm, _) {
        final int unique = vm.totalUniqueCells;
        final int totalM2 = unique * kCellAreaM2;
        final double totalKm2 = totalM2 / 1000000.0;

        // 全エントリを統一型で扱う。Locale で表示名を切替えると同時に
        // regionScope によるフィルタも適用する。
        final rows = <_RankRow>[
          for (final w in worldAreasFor(lang))
            _RankRow(
              name: w.displayName(lang),
              areaKm2: w.areaKm2,
              kind: w.kind,
              iso2: w.iso2,
              isUser: false,
            ),
          _RankRow(
            name: l.you,
            areaKm2: totalKm2,
            kind: 'user',
            iso2: null,
            isUser: true,
          ),
        ]..sort((a, b) {
            final c = b.areaKm2.compareTo(a.areaKm2);
            if (c != 0) return c;
            // タイなら user を下に（同サイズの地物の直後に来る）
            if (a.isUser) return 1;
            if (b.isUser) return -1;
            return 0;
          });

        _userIndex = rows.indexWhere((r) => r.isUser);
        if (_userIndex < 0) _userIndex = 0;
        _scheduleScrollToUser();

        return ListView.builder(
          controller: _scrollCtl,
          itemCount: rows.length,
          itemBuilder: (ctx, i) {
            final r = rows[i];
            return _RankTile(
              rank: i + 1,
              row: r,
              userAreaKm2: totalKm2,
            );
          },
        );
      },
    );
  }
}

/// ランキング 1 行ぶんのデータ。
class _RankRow {
  const _RankRow({
    required this.name,
    required this.areaKm2,
    required this.kind,
    required this.iso2,
    required this.isUser,
  });
  final String name;
  final double areaKm2;
  final String kind;
  final String? iso2;
  final bool isUser;
}

class _RankTile extends StatelessWidget {
  const _RankTile({
    required this.rank,
    required this.row,
    required this.userAreaKm2,
  });
  final int rank;
  final _RankRow row;
  final double userAreaKm2;

  @override
  Widget build(BuildContext context) {
    final f = NumberFormat.decimalPattern();
    final double progress =
        row.areaKm2 == 0 ? 1.0 : (userAreaKm2 / row.areaKm2);
    final l = AppLocalizations.of(context)!;
    final bool isComplete = !row.isUser && progress >= 1.0;
    final double clampedProgress = progress.clamp(0.0, 1.0).toDouble();
    final String pctText = row.isUser
        ? ''
        : '${(progress * 100).toStringAsFixed(progress >= 1 ? 2 : 4)} %';
    final double m2 = row.areaKm2 * 1000000.0;
    final String areaText = l.areaUnitM2(f.format(m2.round()));

    final bg = row.isUser
        ? Colors.green.withValues(alpha: 0.18)
        : (Theme.of(context).brightness == Brightness.dark
            ? Colors.grey[900]
            : Colors.white);
    final border = row.isUser
        ? const Border(
            top: BorderSide(color: Colors.green, width: 1),
            bottom: BorderSide(color: Colors.green, width: 1),
          )
        : Border(
            bottom: BorderSide(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.3)),
          );

    return Container(
      decoration: BoxDecoration(color: bg, border: border),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ランク番号
          SizedBox(
            width: 38,
            child: Text(
              '$rank',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          // アイコン（country は国旗、その他は Material Icons）
          SizedBox(
            width: 32,
            height: 28,
            child: Center(
              child: row.isUser
                  ? const Icon(Icons.person_pin_circle,
                      color: Colors.green, size: 28)
                  : (row.kind == 'country' && row.iso2 != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: CountryFlag.fromCountryCode(
                            row.iso2!,
                            height: 18,
                            width: 28,
                          ),
                        )
                      : Icon(
                          _iconFor(row.kind),
                          color: Colors.grey[600],
                          size: 28,
                        )),
            ),
          ),
          const SizedBox(width: 10),
          // 本体
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        row.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: row.isUser ? Colors.green[700] : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      areaText,
                      style: TextStyle(
                        color: Colors.amber[700],
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (!row.isUser) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: clampedProgress,
                      minHeight: 5,
                      backgroundColor: Colors.grey.withValues(alpha: 0.3),
                      valueColor: AlwaysStoppedAnimation(
                        isComplete ? Colors.amber : Colors.amber,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (isComplete)
                        Text(
                          l.complete,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 12),
                        ),
                      const Spacer(),
                      Text(
                        pctText,
                        style: TextStyle(
                          color: Colors.green[400],
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _iconFor(String kind) {
  switch (kind) {
    case 'country':
      return Icons.flag;
    case 'island':
      return Icons.terrain;
    case 'region':
      return Icons.location_city;
    case 'landmark':
      return Icons.place;
    case 'natural':
      return Icons.public;
    default:
      return Icons.public;
  }
}

// ===========================================================================
// 履歴タブ
// ===========================================================================

class _HistoryEntry {
  const _HistoryEntry({
    required this.date,
    required this.cell1,
    required this.cell2,
    required this.area1,
    required this.area2,
    this.title,
  });

  /// YYYYMMDD 形式の整数（例: 20240908）
  final int date;
  final int cell1;
  final int cell2;
  final double area1;
  final double area2;
  final String? title;

  DateTime get dateTime {
    final y = date ~/ 10000;
    final m = (date ~/ 100) % 100;
    final d = date % 100;
    return DateTime(y, m, d);
  }
}

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  late Future<List<_HistoryEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadHistory();
  }

  Future<List<_HistoryEntry>> _loadHistory() async {
    final dir = await appDatabasesPath();
    final areaPath = p.join(dir, 'area3.db');
    final titlePath = p.join(dir, 'title.db');

    // area3.db が無ければ空テーブル付きで新規作成（履歴 0 件として返す）。
    // 以降の記録更新で `INSERT OR REPLACE` できるようになる。
    if (!await File(areaPath).exists()) {
      final db = await openDatabase(
        areaPath,
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE area_table (
              date INTEGER PRIMARY KEY,
              cell1 INTEGER,
              cell2 INTEGER,
              area1 REAL,
              area2 REAL,
              event1 INTEGER,
              event2 INTEGER,
              event3 INTEGER,
              event4 INTEGER
            )
          ''');
        },
      );
      await db.close();
      return const [];
    }

    Map<int, String> titleMap = {};
    if (await File(titlePath).exists()) {
      final tdb = await openDatabase(titlePath, readOnly: true);
      try {
        final rows =
            await tdb.query('title_table', columns: ['date', 'title']);
        for (final r in rows) {
          final d = r['date'];
          final t = r['title'];
          if (d is int && t is String) titleMap[d] = t;
        }
      } catch (_) {
        // title が無くても致命ではない。
      } finally {
        await tdb.close();
      }
    }

    final adb = await openDatabase(areaPath, readOnly: true);
    try {
      final rows = await adb.query(
        'area_table',
        columns: ['date', 'cell1', 'cell2', 'area1', 'area2'],
        orderBy: 'date DESC',
      );
      return [
        for (final r in rows)
          _HistoryEntry(
            date: (r['date'] as int?) ?? 0,
            cell1: (r['cell1'] as int?) ?? 0,
            cell2: (r['cell2'] as int?) ?? 0,
            area1: (r['area1'] as num?)?.toDouble() ?? 0,
            area2: (r['area2'] as num?)?.toDouble() ?? 0,
            title: titleMap[(r['date'] as int?) ?? 0],
          )
      ];
    } finally {
      await adb.close();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _loadHistory();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<List<_HistoryEntry>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            final l = AppLocalizations.of(context)!;
            return ListView(
              children: [
                const SizedBox(height: 80),
                Center(
                  child: Text(
                    l.statsLoadFailed(snap.error.toString()),
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            );
          }
          final list = snap.data ?? const <_HistoryEntry>[];
          if (list.isEmpty) {
            final l = AppLocalizations.of(context)!;
            return ListView(
              children: [
                const SizedBox(height: 80),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      l.statsHistoryEmpty,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              ],
            );
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) => _HistoryTile(
              entry: list[i],
              onEditTitle: () => _editTitle(list[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _editTitle(_HistoryEntry entry) async {
    final newTitle = await showDialog<String?>(
      context: context,
      builder: (ctx) => _TitleEditDialog(entry: entry),
    );
    if (newTitle == null) return; // キャンセル
    try {
      await DatabaseRepository().setDailyTitle(
        dateKey: entry.date,
        title: newTitle,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)!.saveFailed(e.toString())),
            backgroundColor: Colors.red),
      );
    }
  }
}

/// タイトル編集ダイアログ。StatefulWidget にすることで TextEditingController の
/// ライフサイクルを Flutter のウィジェットツリーと一致させる（外側で dispose() を
/// 呼ぶと _dependents.isEmpty アサートに抵触する）。
class _TitleEditDialog extends StatefulWidget {
  const _TitleEditDialog({required this.entry});
  final _HistoryEntry entry;

  @override
  State<_TitleEditDialog> createState() => _TitleEditDialogState();
}

class _TitleEditDialogState extends State<_TitleEditDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry.title ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(
        DateFormat('yyyy/MM/dd (E)').format(widget.entry.dateTime),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 16,
        decoration: InputDecoration(
          labelText: l.statsTitleLabel,
          hintText: l.statsTitleHint,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: Text(l.delete, style: const TextStyle(color: Colors.red)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l.save),
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry, required this.onEditTitle});
  final _HistoryEntry entry;
  final VoidCallback onEditTitle;

  @override
  Widget build(BuildContext context) {
    final f = NumberFormat.decimalPattern();
    final df = DateFormat('yyyy/MM/dd (E)');
    final dateText = df.format(entry.dateTime);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onEditTitle,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      dateText,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (entry.title != null && entry.title!.isNotEmpty)
                    Flexible(
                      child: Text(
                        entry.title!,
                        style: TextStyle(
                            color: Colors.grey[700], fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  else
                    Icon(Icons.edit_note,
                        size: 16, color: Colors.grey[400]),
                ],
              ),
              const SizedBox(height: 6),
              Builder(builder: (context) {
                final l = AppLocalizations.of(context)!;
                return Row(
                  children: [
                    _MiniMetric(
                      label: l.statsCellNew,
                      value: f.format(entry.cell1),
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 16),
                    _MiniMetric(
                      label: l.statsCellExisting,
                      value: f.format(entry.cell2),
                      color: Colors.grey,
                    ),
                    const Spacer(),
                    Text(
                      l.areaUnitM2(f.format((entry.area1 + entry.area2).toInt())),
                      style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$label ',
          style: TextStyle(color: color, fontSize: 11),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

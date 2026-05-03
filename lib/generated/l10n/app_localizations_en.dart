// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Routepia';

  @override
  String get yes => 'Yes';

  @override
  String get no => 'No';

  @override
  String get ok => 'OK';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get execute => 'Execute';

  @override
  String get later => 'Later';

  @override
  String get openSettings => 'Open Settings';

  @override
  String get loading => 'Loading...';

  @override
  String get extractingFiles => 'Extracting files...';

  @override
  String get you => 'You';

  @override
  String get complete => 'Complete.';

  @override
  String get menuRecordLocation => 'Record Location';

  @override
  String get menuRecording => 'Recording (tap to stop)';

  @override
  String get menuStopped => 'Stopped (tap to resume)';

  @override
  String get menuTileResolution => 'Tile Resolution';

  @override
  String get menuDarkMode => 'Dark Mode';

  @override
  String get menuDarkModeOn => 'Dark (UI + Map)';

  @override
  String get menuDarkModeOff => 'Light (UI + Map)';

  @override
  String get menuMapStyleSettings => 'Map Display Settings';

  @override
  String get menuMapStyleSettingsSubtitle =>
      'Toggle landmarks, stations, transit lines, etc.';

  @override
  String get menuLanguage => 'Language';

  @override
  String get menuLanguageSystem => 'System default';

  @override
  String get menuRebuildLowZoom => 'Rebuild Low-Zoom';

  @override
  String get menuRebuildLowZoomBody =>
      'This may take from tens of seconds to several minutes.';

  @override
  String get menuRebuildInProgress => 'Rebuilding...';

  @override
  String menuRebuildShards(int processed, int total) {
    return '$processed / $total shards';
  }

  @override
  String get menuRebuildScanning => 'Scanning z=14 shards...';

  @override
  String get menuRebuildSuccess => 'Low-zoom rebuild completed';

  @override
  String menuRebuildFailed(String error) {
    return 'Rebuild failed: $error';
  }

  @override
  String get menuClearAll => 'Clear All Records';

  @override
  String get menuClearAllSubtitle => 'Delete all databases';

  @override
  String get menuClearAllConfirmBody =>
      'This will delete all recorded data. This action cannot be undone. Are you sure?';

  @override
  String get menuClearAllDone => 'All records have been deleted';

  @override
  String menuClearAllFailed(String error) {
    return 'Delete failed: $error';
  }

  @override
  String get tileResLow => 'Low (320px)';

  @override
  String get tileResMid => 'Medium (480px)';

  @override
  String get tileResHigh => 'High (512px)';

  @override
  String get mapSettingsTitle => 'Map Display Settings';

  @override
  String get mapSettingsReset => 'Reset';

  @override
  String get mapSectionPoi => 'Landmarks (POI)';

  @override
  String get mapSectionTransit => 'Transit';

  @override
  String get mapSectionLabels => 'Labels';

  @override
  String get poiBusiness => 'Shops & Businesses';

  @override
  String get poiPark => 'Parks';

  @override
  String get poiAttraction => 'Attractions';

  @override
  String get poiGovernment => 'Government';

  @override
  String get poiMedical => 'Hospitals & Medical';

  @override
  String get poiSchool => 'Schools';

  @override
  String get poiPlaceOfWorship => 'Places of Worship';

  @override
  String get poiSportsComplex => 'Sports Facilities';

  @override
  String get transitLine => 'Routes (rail / bus lines)';

  @override
  String get railwayStation => 'Railway Stations';

  @override
  String get busStation => 'Bus Stops';

  @override
  String get airport => 'Airports';

  @override
  String get labelRoad => 'Road Labels';

  @override
  String get labelAdmin => 'Place / Boundary Labels';

  @override
  String get dateFilterHelp => 'Filter by date';

  @override
  String get dateFilterApply => 'Apply';

  @override
  String get locationRationaleTitle => 'About Location Permission';

  @override
  String get locationRationaleBody1 =>
      'This app saves your travel log locally and uses location in the background.';

  @override
  String get locationRationaleBody2 =>
      'Location data is stored only on your device and is never sent to a server.';

  @override
  String get locationRationaleBody3 =>
      'The OS permission dialog will appear next. To record in the background, please choose \"Always Allow\".';

  @override
  String get locationAlwaysTitle => 'Please set location to \"Always Allow\"';

  @override
  String get locationAlwaysBody =>
      'To record your route while the app is closed, this app needs the location permission set to \"Always Allow\".\n\nOpen the app\'s Location setting and select \"Always\".';

  @override
  String get notificationRecordingText => 'Recording travel history...';

  @override
  String get tooltipFollowingOn => 'Following (tap to release)';

  @override
  String get tooltipFollowingOff => 'Center on me';

  @override
  String get tooltipMenu => 'Settings / Menu';

  @override
  String get tooltipMapSatellite => 'Satellite map (tap to switch to blank)';

  @override
  String get tooltipMapBlank => 'Blank map (tap to switch to standard)';

  @override
  String get tooltipMapStandard => 'Standard map (tap to switch to satellite)';

  @override
  String get tooltipResetCamera => 'Reset to north / horizontal';

  @override
  String get fabClose => 'Close (long-press for stats)';

  @override
  String get fabMenu => 'Menu (long-press for stats)';

  @override
  String cellInfoFirst(String date) {
    return 'First update: $date';
  }

  @override
  String cellInfoLast(String date) {
    return 'Last update: $date';
  }

  @override
  String get deleteSection => 'Delete Section';

  @override
  String get deleteSectionConfirmTitle => 'Delete Section';

  @override
  String deleteSectionConfirmBody(int count) {
    return 'Delete data in the selected range?\nThis action cannot be undone.\nTarget cells: $count';
  }

  @override
  String get deleteSelected => 'Delete range selected';

  @override
  String get deleteSelectEnd => 'Tap the end of the section';

  @override
  String deleteExecuteCells(int count) {
    return 'Execute ($count cells)';
  }

  @override
  String get deleteRunningTitle => 'Deleting...';

  @override
  String get deleteDoneTitle => 'Delete Complete';

  @override
  String get deleteDoneBody => 'Section deletion has finished.';

  @override
  String get cellSizeFix => 'Fix cell size at the current zoom';

  @override
  String get statsTitle => 'Stats';

  @override
  String get statsTabAchievement => 'Achievements';

  @override
  String get statsTabHistory => 'History';

  @override
  String statsLoadFailed(String error) {
    return 'Failed to load: $error';
  }

  @override
  String get statsHistoryEmpty =>
      'No history yet.\nKeep walking to build it up.';

  @override
  String get statsTitleLabel => 'Title';

  @override
  String get statsTitleHint => 'Up to 16 chars';

  @override
  String get statsCellNew => 'New';

  @override
  String get statsCellExisting => 'Existing';

  @override
  String saveFailed(String error) {
    return 'Save failed: $error';
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
  String get updateAvailableTitle => 'Update Available';

  @override
  String get updateAvailableBody =>
      'A newer version of the app is available. Update now?';

  @override
  String get updateLater => 'Later';

  @override
  String get updateNow => 'Update';

  @override
  String get continueAction => 'OK (Continue)';

  @override
  String cellSizeLockedTooltip(int z) {
    return 'Z$z (tap to auto)';
  }

  @override
  String get menuRebuildSubtitle => 'Rebuild z=3..13 from z=14 records';
}

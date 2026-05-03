import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Routepia'**
  String get appTitle;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @execute.
  ///
  /// In en, this message translates to:
  /// **'Execute'**
  String get execute;

  /// No description provided for @later.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get later;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get openSettings;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @extractingFiles.
  ///
  /// In en, this message translates to:
  /// **'Extracting files...'**
  String get extractingFiles;

  /// No description provided for @you.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// No description provided for @complete.
  ///
  /// In en, this message translates to:
  /// **'Complete.'**
  String get complete;

  /// No description provided for @menuRecordLocation.
  ///
  /// In en, this message translates to:
  /// **'Record Location'**
  String get menuRecordLocation;

  /// No description provided for @menuRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording (tap to stop)'**
  String get menuRecording;

  /// No description provided for @menuStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped (tap to resume)'**
  String get menuStopped;

  /// No description provided for @menuTileResolution.
  ///
  /// In en, this message translates to:
  /// **'Tile Resolution'**
  String get menuTileResolution;

  /// No description provided for @menuDarkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark Mode'**
  String get menuDarkMode;

  /// No description provided for @menuDarkModeOn.
  ///
  /// In en, this message translates to:
  /// **'Dark (UI + Map)'**
  String get menuDarkModeOn;

  /// No description provided for @menuDarkModeOff.
  ///
  /// In en, this message translates to:
  /// **'Light (UI + Map)'**
  String get menuDarkModeOff;

  /// No description provided for @menuMapStyleSettings.
  ///
  /// In en, this message translates to:
  /// **'Map Display Settings'**
  String get menuMapStyleSettings;

  /// No description provided for @menuMapStyleSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Toggle landmarks, stations, transit lines, etc.'**
  String get menuMapStyleSettingsSubtitle;

  /// No description provided for @menuLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get menuLanguage;

  /// No description provided for @menuLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get menuLanguageSystem;

  /// No description provided for @menuRebuildLowZoom.
  ///
  /// In en, this message translates to:
  /// **'Rebuild Low-Zoom'**
  String get menuRebuildLowZoom;

  /// No description provided for @menuRebuildLowZoomBody.
  ///
  /// In en, this message translates to:
  /// **'This may take from tens of seconds to several minutes.'**
  String get menuRebuildLowZoomBody;

  /// No description provided for @menuRebuildInProgress.
  ///
  /// In en, this message translates to:
  /// **'Rebuilding...'**
  String get menuRebuildInProgress;

  /// No description provided for @menuRebuildShards.
  ///
  /// In en, this message translates to:
  /// **'{processed} / {total} shards'**
  String menuRebuildShards(int processed, int total);

  /// No description provided for @menuRebuildScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning z=14 shards...'**
  String get menuRebuildScanning;

  /// No description provided for @menuRebuildSuccess.
  ///
  /// In en, this message translates to:
  /// **'Low-zoom rebuild completed'**
  String get menuRebuildSuccess;

  /// No description provided for @menuRebuildFailed.
  ///
  /// In en, this message translates to:
  /// **'Rebuild failed: {error}'**
  String menuRebuildFailed(String error);

  /// No description provided for @menuClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear All Records'**
  String get menuClearAll;

  /// No description provided for @menuClearAllSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Delete all databases'**
  String get menuClearAllSubtitle;

  /// No description provided for @menuClearAllConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This will delete all recorded data. This action cannot be undone. Are you sure?'**
  String get menuClearAllConfirmBody;

  /// No description provided for @menuClearAllDone.
  ///
  /// In en, this message translates to:
  /// **'All records have been deleted'**
  String get menuClearAllDone;

  /// No description provided for @menuClearAllFailed.
  ///
  /// In en, this message translates to:
  /// **'Delete failed: {error}'**
  String menuClearAllFailed(String error);

  /// No description provided for @tileResLow.
  ///
  /// In en, this message translates to:
  /// **'Low (320px)'**
  String get tileResLow;

  /// No description provided for @tileResMid.
  ///
  /// In en, this message translates to:
  /// **'Medium (480px)'**
  String get tileResMid;

  /// No description provided for @tileResHigh.
  ///
  /// In en, this message translates to:
  /// **'High (512px)'**
  String get tileResHigh;

  /// No description provided for @mapSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Map Display Settings'**
  String get mapSettingsTitle;

  /// No description provided for @mapSettingsReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get mapSettingsReset;

  /// No description provided for @mapSectionPoi.
  ///
  /// In en, this message translates to:
  /// **'Landmarks (POI)'**
  String get mapSectionPoi;

  /// No description provided for @mapSectionTransit.
  ///
  /// In en, this message translates to:
  /// **'Transit'**
  String get mapSectionTransit;

  /// No description provided for @mapSectionLabels.
  ///
  /// In en, this message translates to:
  /// **'Labels'**
  String get mapSectionLabels;

  /// No description provided for @poiBusiness.
  ///
  /// In en, this message translates to:
  /// **'Shops & Businesses'**
  String get poiBusiness;

  /// No description provided for @poiPark.
  ///
  /// In en, this message translates to:
  /// **'Parks'**
  String get poiPark;

  /// No description provided for @poiAttraction.
  ///
  /// In en, this message translates to:
  /// **'Attractions'**
  String get poiAttraction;

  /// No description provided for @poiGovernment.
  ///
  /// In en, this message translates to:
  /// **'Government'**
  String get poiGovernment;

  /// No description provided for @poiMedical.
  ///
  /// In en, this message translates to:
  /// **'Hospitals & Medical'**
  String get poiMedical;

  /// No description provided for @poiSchool.
  ///
  /// In en, this message translates to:
  /// **'Schools'**
  String get poiSchool;

  /// No description provided for @poiPlaceOfWorship.
  ///
  /// In en, this message translates to:
  /// **'Places of Worship'**
  String get poiPlaceOfWorship;

  /// No description provided for @poiSportsComplex.
  ///
  /// In en, this message translates to:
  /// **'Sports Facilities'**
  String get poiSportsComplex;

  /// No description provided for @transitLine.
  ///
  /// In en, this message translates to:
  /// **'Routes (rail / bus lines)'**
  String get transitLine;

  /// No description provided for @railwayStation.
  ///
  /// In en, this message translates to:
  /// **'Railway Stations'**
  String get railwayStation;

  /// No description provided for @busStation.
  ///
  /// In en, this message translates to:
  /// **'Bus Stops'**
  String get busStation;

  /// No description provided for @airport.
  ///
  /// In en, this message translates to:
  /// **'Airports'**
  String get airport;

  /// No description provided for @labelRoad.
  ///
  /// In en, this message translates to:
  /// **'Road Labels'**
  String get labelRoad;

  /// No description provided for @labelAdmin.
  ///
  /// In en, this message translates to:
  /// **'Place / Boundary Labels'**
  String get labelAdmin;

  /// No description provided for @dateFilterHelp.
  ///
  /// In en, this message translates to:
  /// **'Filter by date'**
  String get dateFilterHelp;

  /// No description provided for @dateFilterApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get dateFilterApply;

  /// No description provided for @locationRationaleTitle.
  ///
  /// In en, this message translates to:
  /// **'About Location Permission'**
  String get locationRationaleTitle;

  /// No description provided for @locationRationaleBody1.
  ///
  /// In en, this message translates to:
  /// **'This app saves your travel log locally and uses location in the background.'**
  String get locationRationaleBody1;

  /// No description provided for @locationRationaleBody2.
  ///
  /// In en, this message translates to:
  /// **'Location data is stored only on your device and is never sent to a server.'**
  String get locationRationaleBody2;

  /// No description provided for @locationRationaleBody3.
  ///
  /// In en, this message translates to:
  /// **'The OS permission dialog will appear next. To record in the background, please choose \"Always Allow\".'**
  String get locationRationaleBody3;

  /// No description provided for @locationAlwaysTitle.
  ///
  /// In en, this message translates to:
  /// **'Please set location to \"Always Allow\"'**
  String get locationAlwaysTitle;

  /// No description provided for @locationAlwaysBody.
  ///
  /// In en, this message translates to:
  /// **'To record your route while the app is closed, this app needs the location permission set to \"Always Allow\".\n\nOpen the app\'s Location setting and select \"Always\".'**
  String get locationAlwaysBody;

  /// No description provided for @notificationRecordingText.
  ///
  /// In en, this message translates to:
  /// **'Recording travel history...'**
  String get notificationRecordingText;

  /// No description provided for @tooltipFollowingOn.
  ///
  /// In en, this message translates to:
  /// **'Following (tap to release)'**
  String get tooltipFollowingOn;

  /// No description provided for @tooltipFollowingOff.
  ///
  /// In en, this message translates to:
  /// **'Center on me'**
  String get tooltipFollowingOff;

  /// No description provided for @tooltipMenu.
  ///
  /// In en, this message translates to:
  /// **'Settings / Menu'**
  String get tooltipMenu;

  /// No description provided for @tooltipMapSatellite.
  ///
  /// In en, this message translates to:
  /// **'Satellite map (tap to switch to blank)'**
  String get tooltipMapSatellite;

  /// No description provided for @tooltipMapBlank.
  ///
  /// In en, this message translates to:
  /// **'Blank map (tap to switch to standard)'**
  String get tooltipMapBlank;

  /// No description provided for @tooltipMapStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard map (tap to switch to satellite)'**
  String get tooltipMapStandard;

  /// No description provided for @tooltipResetCamera.
  ///
  /// In en, this message translates to:
  /// **'Reset to north / horizontal'**
  String get tooltipResetCamera;

  /// No description provided for @fabClose.
  ///
  /// In en, this message translates to:
  /// **'Close (long-press for stats)'**
  String get fabClose;

  /// No description provided for @fabMenu.
  ///
  /// In en, this message translates to:
  /// **'Menu (long-press for stats)'**
  String get fabMenu;

  /// No description provided for @cellInfoFirst.
  ///
  /// In en, this message translates to:
  /// **'First update: {date}'**
  String cellInfoFirst(String date);

  /// No description provided for @cellInfoLast.
  ///
  /// In en, this message translates to:
  /// **'Last update: {date}'**
  String cellInfoLast(String date);

  /// No description provided for @deleteSection.
  ///
  /// In en, this message translates to:
  /// **'Delete Section'**
  String get deleteSection;

  /// No description provided for @deleteSectionConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Section'**
  String get deleteSectionConfirmTitle;

  /// No description provided for @deleteSectionConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Delete data in the selected range?\nThis action cannot be undone.\nTarget cells: {count}'**
  String deleteSectionConfirmBody(int count);

  /// No description provided for @deleteSelected.
  ///
  /// In en, this message translates to:
  /// **'Delete range selected'**
  String get deleteSelected;

  /// No description provided for @deleteSelectEnd.
  ///
  /// In en, this message translates to:
  /// **'Tap the end of the section'**
  String get deleteSelectEnd;

  /// No description provided for @deleteExecuteCells.
  ///
  /// In en, this message translates to:
  /// **'Execute ({count} cells)'**
  String deleteExecuteCells(int count);

  /// No description provided for @deleteRunningTitle.
  ///
  /// In en, this message translates to:
  /// **'Deleting...'**
  String get deleteRunningTitle;

  /// No description provided for @deleteDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Complete'**
  String get deleteDoneTitle;

  /// No description provided for @deleteDoneBody.
  ///
  /// In en, this message translates to:
  /// **'Section deletion has finished.'**
  String get deleteDoneBody;

  /// No description provided for @cellSizeFix.
  ///
  /// In en, this message translates to:
  /// **'Fix cell size at the current zoom'**
  String get cellSizeFix;

  /// No description provided for @statsTitle.
  ///
  /// In en, this message translates to:
  /// **'Stats'**
  String get statsTitle;

  /// No description provided for @statsTabAchievement.
  ///
  /// In en, this message translates to:
  /// **'Achievements'**
  String get statsTabAchievement;

  /// No description provided for @statsTabHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get statsTabHistory;

  /// No description provided for @statsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load: {error}'**
  String statsLoadFailed(String error);

  /// No description provided for @statsHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No history yet.\nKeep walking to build it up.'**
  String get statsHistoryEmpty;

  /// No description provided for @statsTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get statsTitleLabel;

  /// No description provided for @statsTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Up to 16 chars'**
  String get statsTitleHint;

  /// No description provided for @statsCellNew.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get statsCellNew;

  /// No description provided for @statsCellExisting.
  ///
  /// In en, this message translates to:
  /// **'Existing'**
  String get statsCellExisting;

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String saveFailed(String error);

  /// No description provided for @areaUnitM2.
  ///
  /// In en, this message translates to:
  /// **'{value} m²'**
  String areaUnitM2(String value);

  /// No description provided for @areaUnitKm2.
  ///
  /// In en, this message translates to:
  /// **'{value} km²'**
  String areaUnitKm2(String value);

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Update Available'**
  String get updateAvailableTitle;

  /// No description provided for @updateAvailableBody.
  ///
  /// In en, this message translates to:
  /// **'A newer version of the app is available. Update now?'**
  String get updateAvailableBody;

  /// No description provided for @updateLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updateLater;

  /// No description provided for @updateNow.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updateNow;

  /// No description provided for @continueAction.
  ///
  /// In en, this message translates to:
  /// **'OK (Continue)'**
  String get continueAction;

  /// No description provided for @cellSizeLockedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Z{z} (tap to auto)'**
  String cellSizeLockedTooltip(int z);

  /// No description provided for @menuRebuildSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Rebuild z=3..13 from z=14 records'**
  String get menuRebuildSubtitle;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}

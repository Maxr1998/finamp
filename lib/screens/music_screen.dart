import 'dart:io';

import 'package:Finamp/services/queue_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:logging/logging.dart';

import '../components/MusicScreen/music_screen_drawer.dart';
import '../components/MusicScreen/music_screen_tab_view.dart';
import '../components/MusicScreen/sort_by_menu_button.dart';
import '../components/MusicScreen/sort_order_button.dart';
import '../components/global_snackbar.dart';
import '../components/now_playing_bar.dart';
import '../models/finamp_models.dart';
import '../services/audio_service_helper.dart';
import '../services/finamp_settings_helper.dart';
import '../services/finamp_user_helper.dart';
import '../services/jellyfin_api_helper.dart';

class MusicScreen extends ConsumerStatefulWidget {
  const MusicScreen({super.key});

  static const routeName = "/music";

  @override
  ConsumerState<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends ConsumerState<MusicScreen>
    with TickerProviderStateMixin {
  bool isSearching = false;
  bool _showShuffleFab = false;
  TextEditingController textEditingController = TextEditingController();
  String? searchQuery;
  final _musicScreenLogger = Logger("MusicScreen");
  final Map<TabContentType, MusicRefreshCallback> refreshMap = {};

  TabController? _tabController;

  final _audioServiceHelper = GetIt.instance<AudioServiceHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _queueService = GetIt.instance<QueueService>();

  void _stopSearching() {
    setState(() {
      textEditingController.clear();
      searchQuery = null;
      isSearching = false;
    });
  }

  void _tabIndexCallback() {
    var tabKey = FinampSettingsHelper.finampSettings.showTabs.entries
        .where((element) => element.value)
        .elementAt(_tabController!.index)
        .key;
    if (_tabController != null &&
        (tabKey == TabContentType.songs ||
            tabKey == TabContentType.artists ||
            tabKey == TabContentType.albums)) {
      setState(() {
        _showShuffleFab = true;
      });
    } else {
      if (_showShuffleFab) {
        setState(() {
          _showShuffleFab = false;
        });
      }
    }
  }

  void _buildTabController() {
    _tabController?.removeListener(_tabIndexCallback);

    _tabController = TabController(
      length: FinampSettingsHelper.finampSettings.showTabs.entries
          .where((element) => element.value)
          .length,
      vsync: this,
      initialIndex: ModalRoute.of(context)?.settings.arguments as int? ?? 0,
    );

    _tabController!.addListener(_tabIndexCallback);
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  FloatingActionButton? getFloatingActionButton(
      List<TabContentType> sortedTabs) {
    // Show the floating action button only on the albums, artists, generes and songs tab.
    if (_tabController!.index == sortedTabs.indexOf(TabContentType.songs)) {
      return FloatingActionButton(
        tooltip: AppLocalizations.of(context)!.shuffleAll,
        onPressed: () async {
          try {
            await _audioServiceHelper.shuffleAll(
                FinampSettingsHelper.finampSettings.onlyShowFavourite);
          } catch (e) {
            GlobalSnackbar.error(e);
          }
        },
        child: const Icon(Icons.shuffle),
      );
    } else if (_tabController!.index ==
        sortedTabs.indexOf(TabContentType.artists)) {
      return FloatingActionButton(
          tooltip: AppLocalizations.of(context)!.startMix,
          onPressed: () async {
            try {
              if (_jellyfinApiHelper.selectedMixArtists.isEmpty) {
                GlobalSnackbar.message((scaffold) =>
                    AppLocalizations.of(context)!.startMixNoSongsArtist);
              } else {
                await _audioServiceHelper.startInstantMixForArtists(
                    _jellyfinApiHelper.selectedMixArtists);
                _jellyfinApiHelper.clearArtistMixBuilderList();
              }
            } catch (e) {
              GlobalSnackbar.error(e);
            }
          },
          child: const Icon(Icons.explore));
    } else if (_tabController!.index ==
        sortedTabs.indexOf(TabContentType.albums)) {
      return FloatingActionButton(
          tooltip: AppLocalizations.of(context)!.startMix,
          onPressed: () async {
            try {
              if (_jellyfinApiHelper.selectedMixAlbums.isEmpty) {
                GlobalSnackbar.message((scaffold) =>
                    AppLocalizations.of(context)!.startMixNoSongsAlbum);
              } else {
                await _audioServiceHelper.startInstantMixForAlbums(
                    _jellyfinApiHelper.selectedMixAlbums);
              }
            } catch (e) {
              GlobalSnackbar.error(e);
            }
          },
          child: const Icon(Icons.explore));
    } else if (_tabController!.index ==
        sortedTabs.indexOf(TabContentType.genres)) {
      return FloatingActionButton(
          tooltip: AppLocalizations.of(context)!.startMix,
          onPressed: () async {
            try {
              if (_jellyfinApiHelper.selectedMixGenres.isEmpty) {
                GlobalSnackbar.message((scaffold) =>
                    AppLocalizations.of(context)!.startMixNoSongsGenre);
              } else {
                await _audioServiceHelper.startInstantMixForGenres(
                    _jellyfinApiHelper.selectedMixGenres);
              }
            } catch (e) {
              GlobalSnackbar.error(e);
            }
          },
          child: const Icon(Icons.explore));
    } else {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _queueService
        .performInitialQueueLoad()
        .catchError((x) => GlobalSnackbar.error(x));
    if (_tabController == null) {
      _buildTabController();
    }
    ref.watch(FinampUserHelper.finampCurrentUserProvider);
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, value, _) {
        final finampSettings = value.get("FinampSettings");

        // Get the tabs from the user's tab order, and filter them to only
        // include enabled tabs
        final sortedTabs = finampSettings!.tabOrder.where(
            (e) => FinampSettingsHelper.finampSettings.showTabs[e] ?? false);
        refreshMap[sortedTabs.elementAt(_tabController!.index)] =
            MusicRefreshCallback();

        if (sortedTabs.length != _tabController?.length) {
          _musicScreenLogger.info(
              "Rebuilding MusicScreen tab controller (${sortedTabs.length} != ${_tabController?.length})");
          _buildTabController();
        }

        return PopScope(
          canPop: !isSearching,
          onPopInvoked: (popped) {
            if (isSearching) {
              _stopSearching();
            }
          },
          child: Scaffold(
            extendBody: true,
            appBar: AppBar(
              titleSpacing:
                  0, // The surrounding iconButtons provide enough padding
              title: isSearching
                  ? TextField(
                      controller: textEditingController,
                      autofocus: true,
                      onChanged: (value) => setState(() {
                        searchQuery = value;
                      }),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText:
                            MaterialLocalizations.of(context).searchFieldLabel,
                      ),
                    )
                  : Text(_finampUserHelper.currentUser?.currentView?.name ??
                      AppLocalizations.of(context)!.music),
              bottom: TabBar(
                controller: _tabController,
                tabs: sortedTabs
                    .map((tabType) => Tab(
                          text:
                              tabType.toLocalisedString(context).toUpperCase(),
                        ))
                    .toList(),
                isScrollable: true,
                tabAlignment: TabAlignment.start,
              ),
              leading: isSearching
                  ? BackButton(
                      onPressed: () => _stopSearching(),
                    )
                  : null,
              actions: isSearching
                  ? [
                      IconButton(
                        icon: Icon(
                          Icons.cancel,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        onPressed: () => setState(() {
                          textEditingController.clear();
                          searchQuery = null;
                        }),
                        tooltip: AppLocalizations.of(context)!.clear,
                      )
                    ]
                  : [
                      if (!Platform.isIOS && !Platform.isAndroid)
                        IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: () {
                              refreshMap[
                                  sortedTabs.elementAt(_tabController!.index)]!();
                            }),
                      SortOrderButton(
                        sortedTabs.elementAt(_tabController!.index),
                      ),
                      SortByMenuButton(
                        sortedTabs.elementAt(_tabController!.index),
                      ),
                      if (finampSettings.isOffline)
                        IconButton(
                          icon: finampSettings.onlyShowFullyDownloaded
                              ? const Icon(Icons.download)
                              : const Icon(Icons.download_outlined),
                          onPressed: finampSettings.isOffline
                              ? () => FinampSettingsHelper
                                  .setOnlyShowFullyDownloaded(
                                      !finampSettings.onlyShowFullyDownloaded)
                              : null,
                          tooltip: AppLocalizations.of(context)!
                              .onlyShowFullyDownloaded,
                        ),
                      if (!finampSettings.isOffline)
                        IconButton(
                          icon: finampSettings.onlyShowFavourite
                              ? const Icon(Icons.favorite)
                              : const Icon(Icons.favorite_outline),
                          onPressed: finampSettings.isOffline
                              ? null
                              : () => FinampSettingsHelper.setOnlyShowFavourite(
                                  !finampSettings.onlyShowFavourite),
                          tooltip: AppLocalizations.of(context)!.favourites,
                        ),
                      IconButton(
                        icon: const Icon(Icons.search),
                        onPressed: () => setState(() {
                          isSearching = true;
                        }),
                        tooltip:
                            MaterialLocalizations.of(context).searchFieldLabel,
                      ),
                    ],
            ),
            bottomNavigationBar: const NowPlayingBar(),
            drawer: const MusicScreenDrawer(),
            floatingActionButton: Padding(
              padding: EdgeInsets.only(
                  right: FinampSettingsHelper.finampSettings.showFastScroller
                      ? 24.0
                      : 8.0),
              child: getFloatingActionButton(sortedTabs.toList()),
            ),
            body: TabBarView(
              controller: _tabController,
              physics: FinampSettingsHelper.finampSettings.disableGesture
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              dragStartBehavior: DragStartBehavior.down,
              children: sortedTabs
                  .map((tabType) => MusicScreenTabView(
                        tabContentType: tabType,
                        searchTerm: searchQuery,
                        view: _finampUserHelper.currentUser?.currentView,
                        refresh: refreshMap[tabType],
                      ))
                  .toList(),
            ),
          ),
        );
      },
    );
  }
}

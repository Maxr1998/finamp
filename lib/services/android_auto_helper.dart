import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:get_it/get_it.dart';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'downloads_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';
import 'finamp_settings_helper.dart';
import 'queue_service.dart';
import 'audio_service_helper.dart';

class AndroidAutoHelper {

  static final _androidAutoHelperLogger = Logger("AndroidAutoHelper");
  
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _downloadsHelper = GetIt.instance<DownloadsHelper>();

  Future<BaseItemDto?> getParentFromId(String parentId) async {
    if (parentId == '-1') return null;

    final downloadedParent = _downloadsHelper.getDownloadedParent(parentId)?.item;
    if (downloadedParent != null) {
      return downloadedParent;
    } else if (FinampSettingsHelper.finampSettings.isOffline) {
      return null;
    }

    return await _jellyfinApiHelper.getItemById(parentId);
  }

  Future<List<BaseItemDto>> getBaseItems(String type, String parentId, String? itemId) async {
    final tabContentType = TabContentType.values.firstWhere((e) => e.name == type);

    // limit amount so it doesn't crash on large libraries
    // TODO: somehow load more after the limit
    //       a problem with this is: how? i don't *think* there is a callback for scrolling. maybe there could be a button to load more?
    const limit = 100;

    final sortBy = FinampSettingsHelper.finampSettings.getTabSortBy(tabContentType);
    final sortOrder = FinampSettingsHelper.finampSettings.getSortOrder(tabContentType);

    // if we are in offline mode and in root parent/collection, display all matching downloaded parents
    if (FinampSettingsHelper.finampSettings.isOffline && parentId == '-1') {
      List<BaseItemDto> baseItems = [];
      for (final downloadedParent in _downloadsHelper.downloadedParents) {
        if (baseItems.length >= limit) break;
        if (downloadedParent.item.type == tabContentType.itemType()) {
          baseItems.add(downloadedParent.item);
        }
      }
      return _sortItems(baseItems, sortBy, sortOrder);
    }

    // try to use downloaded parent first
    if (parentId != '-1') {
      var downloadedParent = _downloadsHelper.getDownloadedParent(parentId);
      if (downloadedParent != null) {
        final downloadedItems = [for (final child in downloadedParent.downloadedChildren.values.whereIndexed((i, e) => i < limit)) child];
        // only sort items if we are not playing them
        return _isPlayable(tabContentType) ? downloadedItems : _sortItems(downloadedItems, sortBy, sortOrder);
      }
    }

    // fetch the online version if we can't get offline version

    // select the item type that each parent holds
    final includeItemTypes = parentId != '-1' // if parentId is -1, we are browsing a root library. e.g. browsing the list of all albums or artists
        ? (tabContentType == TabContentType.albums ? TabContentType.songs.itemType() // get an album's songs
        : tabContentType == TabContentType.artists ? TabContentType.albums.itemType() // get an artist's albums
        : tabContentType == TabContentType.playlists ? TabContentType.songs.itemType() // get a playlist's songs
        : tabContentType == TabContentType.genres ? TabContentType.albums.itemType() // get a genre's albums
        : TabContentType.songs.itemType() ) // if we don't have one of these categories, we are probably dealing with stray songs
        : tabContentType.itemType(); // get the root library

    // if parent id is defined, use that to get items.
    // otherwise, use the current view as fallback to ensure we get the correct items.
    final parentItem = parentId != '-1'
        ? BaseItemDto(id: parentId, type: tabContentType.itemType())
        : _finampUserHelper.currentUser?.currentView;

    final items = await _jellyfinApiHelper.getItems(parentItem: parentItem, sortBy: sortBy.jellyfinName(tabContentType), sortOrder: sortOrder.toString(), includeItemTypes: includeItemTypes, isGenres: tabContentType == TabContentType.genres, limit: limit);
    return items ?? [];
  }

  Future<List<MediaItem>> searchItems(String query) async {
    final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
    final finampUserHelper = GetIt.instance<FinampUserHelper>();

    try {
      final searchResult = await jellyfinApiHelper.getItems(
        parentItem: finampUserHelper.currentUser?.currentView,
        includeItemTypes: "Audio",
        searchTerm: query.trim(),
        isGenres: false,
        startIndex: 0,
        limit: 20,
      );

      const parentItemSignalInstantMix = "-2";
      return [ for (final item in searchResult!) await _convertToMediaItem(item, parentItemSignalInstantMix) ];
    } catch (err) {
      _androidAutoHelperLogger.severe("Error while searching:", err);
      return [];
    }
  }

  Future<List<MediaItem>> getMediaItems(String type, String parentId, String? itemId) async {
    return [ for (final item in await getBaseItems(type, parentId, itemId)) await _convertToMediaItem(item, parentId) ];
  }

  Future<void> toggleShuffle() async {
    final queueService = GetIt.instance<QueueService>();
    queueService.togglePlaybackOrder();
  }

  Future<void> playFromMediaId(String type, String parentId, String? itemId) async {
    final audioServiceHelper = GetIt.instance<AudioServiceHelper>();
    final tabContentType = TabContentType.values.firstWhere((e) => e.name == type);

    // shouldn't happen, but just in case
    if (parentId == '-1' || !_isPlayable(tabContentType)) {
      _androidAutoHelperLogger.warning("Tried to play from media id with non-playable item type $type");
    };

    if (parentId == '-2') {
      return await audioServiceHelper.startInstantMixForItem(await _jellyfinApiHelper.getItemById(itemId!));
    }

    // get all songs of current parrent
    final parentItem = await getParentFromId(parentId);

    // start instant mix for artists
    if (tabContentType == TabContentType.artists) {
      // we don't show artists in offline mode, and parent item can't be null for mix
      // this shouldn't happen, but just in case
      if (FinampSettingsHelper.finampSettings.isOffline || parentItem == null) {
        return;
      }

      return await audioServiceHelper.startInstantMixForArtists([parentItem]);
    }

    final parentBaseItems = await getBaseItems(type, parentId, itemId);

    // queue service should be initialized by time we get here
    final queueService = GetIt.instance<QueueService>();
    await queueService.startPlayback(items: parentBaseItems, source: QueueItemSource(
      type: tabContentType == TabContentType.playlists
          ? QueueItemSourceType.playlist
          : QueueItemSourceType.album,
      name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: parentItem?.name),
      id: parentItem?.id ?? parentId,
      item: parentItem,
    ));
  }

  // sort items
  List<BaseItemDto> _sortItems(List<BaseItemDto> items, SortBy sortBy, SortOrder sortOrder) {
    items.sort((a, b) {
      switch (sortBy) {
        case SortBy.sortName:
          final aName = a.name?.trim().toLowerCase();
          final bName = b.name?.trim().toLowerCase();
          if (aName == null || bName == null) {
            // Returning 0 is the same as both being the same
            return 0;
          } else {
            return aName.compareTo(bName);
          }
        case SortBy.albumArtist:
          if (a.albumArtist == null || b.albumArtist == null) {
            return 0;
          } else {
            return a.albumArtist!.compareTo(b.albumArtist!);
          }
        case SortBy.communityRating:
          if (a.communityRating == null ||
              b.communityRating == null) {
            return 0;
          } else {
            return a.communityRating!.compareTo(b.communityRating!);
          }
        case SortBy.criticRating:
          if (a.criticRating == null || b.criticRating == null) {
            return 0;
          } else {
            return a.criticRating!.compareTo(b.criticRating!);
          }
        case SortBy.dateCreated:
          if (a.dateCreated == null || b.dateCreated == null) {
            return 0;
          } else {
            return a.dateCreated!.compareTo(b.dateCreated!);
          }
        case SortBy.premiereDate:
          if (a.premiereDate == null || b.premiereDate == null) {
            return 0;
          } else {
            return a.premiereDate!.compareTo(b.premiereDate!);
          }
        case SortBy.random:
        // We subtract the result by one so that we can get -1 values
        // (see compareTo documentation)
          return Random().nextInt(2) - 1;
        default:
          throw UnimplementedError(
              "Unimplemented offline sort mode $sortBy");
      }
    });

    if (sortOrder == SortOrder.descending) {
      // The above sort functions sort in ascending order, so we swap them
      // when sorting in descending order.
      items = items.reversed.toList();
    }

    return items;
  }

  // albums, playlists, and songs should play when clicked
  // clicking artists starts an instant mix, so they are technically playable
  // genres has subcategories, so it should be browsable but not playable
  bool _isPlayable(TabContentType tabContentType) {
    return tabContentType == TabContentType.albums || tabContentType == TabContentType.playlists
        || tabContentType == TabContentType.artists || tabContentType == TabContentType.songs;
  }

  Future<MediaItem> _convertToMediaItem(BaseItemDto item, String parentId) async {
    final tabContentType = TabContentType.fromItemType(item.type!);
    var newId = '${tabContentType.name}|';
    // if item is a parent type (category/collection), set newId to 'type|parentId'. otherwise, if it's a specific item (song), set it to 'type|parentId|itemId'
    if (item.isFolder ?? tabContentType != TabContentType.songs && parentId == '-1') {
      newId += item.id;
    } else {
      newId += '$parentId|${item.id}';
    }

    final downloadedSong = _downloadsHelper.getDownloadedSong(item.id);
    final isDownloaded = downloadedSong == null
        ? false
        : await _downloadsHelper.verifyDownloadedSong(downloadedSong);

    var downloadedImage = _downloadsHelper.getDownloadedImage(item);
    Uri? artUri;

    // replace with content uri or jellyfin api uri
    if (downloadedImage != null) {
      artUri = downloadedImage.file.uri.replace(scheme: "content", host: "com.unicornsonlsd.finamp");
    } else if (!FinampSettingsHelper.finampSettings.isOffline) {
      artUri = _jellyfinApiHelper.getImageUrl(item: item);
      // try to get image file for Android Automotive
      // if (artUri != null) {
      //   try {
      //     final file = (await AudioService.cacheManager.getFileFromMemory(item.id))?.file ?? await AudioService.cacheManager.getSingleFile(artUri.toString());
      //     artUri = file.uri.replace(scheme: "content", host: "com.unicornsonlsd.finamp");
      //   } catch (e, st) {
      //     _androidAutoHelperLogger.fine("Error getting image file for Android Automotive", e, st);
      //   }
      // }
    }

    // replace with placeholder art
    if (artUri == null) {
      final documentsDirectory = await getApplicationDocumentsDirectory();
      artUri = Uri(scheme: "content", host: "com.unicornsonlsd.finamp", path: "${documentsDirectory.absolute.path}/images/album_white.png");
    }

    return MediaItem(
      id: newId,
      playable: _isPlayable(tabContentType), // this dictates whether clicking on an item will try to play it or browse it
      album: item.album,
      artist: item.artists?.join(", ") ?? item.albumArtist,
      artUri: artUri,
      title: item.name ?? "unknown",
      extras: {
        "itemJson": item.toJson(),
        "shouldTranscode": FinampSettingsHelper.finampSettings.shouldTranscode,
        "downloadedSongJson": isDownloaded
            ? (_downloadsHelper.getDownloadedSong(item.id))!.toJson()
            : null,
        "isOffline": FinampSettingsHelper.finampSettings.isOffline,
      },
      // Jellyfin returns microseconds * 10 for some reason
      duration: Duration(
        microseconds:
        (item.runTimeTicks == null ? 0 : item.runTimeTicks! ~/ 10),
      ),
    );
  }
}

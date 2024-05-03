import 'dart:async';

import 'package:finamp/models/finamp_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import '../models/jellyfin_models.dart';
import 'downloads_service.dart';
import 'finamp_settings_helper.dart';
import 'jellyfin_api_helper.dart';

final metadataProviderLogger = Logger("MetadataProvider");

class MetadataRequest {
  const MetadataRequest({
    required this.item,
    this.queueItem,
    this.includeLyrics = false,
    this.checkIfSpeedControlNeeded = false,
  }) : super();

  final BaseItemDto item;
  final FinampQueueItem? queueItem;

  final bool includeLyrics;
  final bool checkIfSpeedControlNeeded;

  @override
  bool operator ==(Object other) {
    return other is MetadataRequest &&
        other.includeLyrics == includeLyrics &&
        other.checkIfSpeedControlNeeded == checkIfSpeedControlNeeded &&
        other.item.id == item.id &&
        other.queueItem?.id == queueItem?.id;
  }

  @override
  int get hashCode => Object.hash(item.id, queueItem?.id, includeLyrics, checkIfSpeedControlNeeded);
}

class MetadataProvider {

  final MediaSourceInfo mediaSourceInfo;
  LyricDto? lyrics;
  bool isDownloaded;
  bool qualifiesForPlaybackSpeedControl;

  MetadataProvider({
    required this.mediaSourceInfo,
    this.lyrics,
    this.isDownloaded = false,
    this.qualifiesForPlaybackSpeedControl = false,
  });

  bool get hasLyrics => mediaSourceInfo.mediaStreams.any((e) => e.type == "Lyric");

}

final AutoDisposeFutureProviderFamily<MetadataProvider?, MetadataRequest>
    metadataProvider = FutureProvider.autoDispose.family<MetadataProvider?, MetadataRequest>((ref, request) async {

  unawaited(ref.watch(FinampSettingsHelper.finampSettingsProvider.selectAsync((settings) => settings?.isOffline))); // watch settings to trigger re-fetching metadata when offline mode changes

  final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final downloadsService = GetIt.instance<DownloadsService>();

  metadataProviderLogger.fine("Fetching metadata for '${request.item.name}' (${request.item.id})");

  MediaSourceInfo? playbackInfo;
  MediaSourceInfo? localPlaybackInfo;
  
  final downloadStub = await downloadsService.getSongInfo(id: request.item.id);
  if (downloadStub != null) {
    final downloadItem = await ref.watch(downloadsService.itemProvider(downloadStub).future);
    if (downloadItem != null && downloadItem.state.isComplete) {
      metadataProviderLogger.fine("Got offline metadata for '${request.item.name}'");
      var profile = downloadItem.fileTranscodingProfile;
      var codec = profile?.codec == FinampTranscodingCodec.original ? downloadItem.baseItem?.mediaSources?.first.container : profile?.codec.name ?? FinampTranscodingCodec.original.name;
      localPlaybackInfo = MediaSourceInfo(
        id: downloadItem.baseItem!.id,
        protocol: "File",
        type: "Default",
        isRemote: false,
        supportsTranscoding: false,
        supportsDirectStream: false,
        supportsDirectPlay: true,
        isInfiniteStream: false,
        requiresOpening: false,
        requiresClosing: false,
        requiresLooping: false,
        supportsProbing: false,
        mediaStreams: downloadItem.baseItem!.mediaStreams?.map((mediaStream) {
          // if we transcoded the file, we need to update the original bitrate
          // the bitrate of the MediaSource(Info) includes all streams, so we prefer the media stream bitrate and hence update it here
          if (mediaStream.type == "Audio") {
            mediaStream.bitRate = profile?.stereoBitrate;
          }
          return mediaStream;
        }).toList() ?? [],
        readAtNativeFramerate: false,
        ignoreDts: false,
        ignoreIndex: false,
        genPtsInput: false,
        bitrate: profile?.stereoBitrate,
        container: codec,
        name: downloadItem.baseItem!.mediaSources?.first.name,
        size: await downloadsService.getFileSize(downloadStub),
      );
    }
  }
  
  //!!! only use offline metadata if the app is in offline mode
  // Finamp should always use the server metadata when online, if possible
  if (FinampSettingsHelper.finampSettings.isOffline) {
    playbackInfo = localPlaybackInfo;
  } else {
    // fetch from server in online mode
    metadataProviderLogger.fine("Fetching metadata for '${request.item.name}' (${request.item.id}) from server due to missing attributes");
    try {
      playbackInfo = (await jellyfinApiHelper.getPlaybackInfo(request.item.id))?.first;
    } catch (e) {
      metadataProviderLogger.severe("Failed to fetch metadata for '${request.item.name}' (${request.item.id})", e);
      return null;
    }

    // update **PARTS** of playbackInfo with localPlaybackInfo if available
    if (localPlaybackInfo != null && playbackInfo != null) {
      playbackInfo.protocol = localPlaybackInfo.protocol;
      playbackInfo.bitrate = localPlaybackInfo.bitrate;
      playbackInfo.container = localPlaybackInfo.container;
      playbackInfo.size = localPlaybackInfo.size;
    }
  }

  if (playbackInfo == null) {
    metadataProviderLogger.warning("Couldn't load metadata for '${request.item.name}' (${request.item.id})");
    return null;
  }

  final metadata = MetadataProvider(mediaSourceInfo: playbackInfo, isDownloaded: localPlaybackInfo != null);

  // check if item qualifies for having playback speed control available
  if (request.checkIfSpeedControlNeeded) {

    for (final genre in request.item.genres ?? []) {
      if (["audiobook", "podcast", "speech"].contains(genre.toLowerCase())) {
        metadata.qualifiesForPlaybackSpeedControl = true;
        break;
      }
    }
    if (!metadata.qualifiesForPlaybackSpeedControl && metadata.mediaSourceInfo.runTimeTicks! > const Duration(minutes: 15).inMicroseconds * 10) {
      // we might want playback speed control for long tracks (like podcasts or audiobook chapters)
      metadata.qualifiesForPlaybackSpeedControl = true;
    } else {
      // check if "album" is long enough to qualify for playback speed control
      try {
        final parent = await jellyfinApiHelper.getItemById(request.item.parentId!);
        if (parent.runTimeTicks! > const Duration(hours: 3).inMicroseconds * 10) {
          metadata.qualifiesForPlaybackSpeedControl = true;
        }
      } catch(e) {
        metadataProviderLogger.warning("Failed to check if '${request.item.name}' (${request.item.id}) qualifies for playback speed controls", e);
      }
    }

  }

  if (request.includeLyrics && metadata.hasLyrics) {

    //!!! only use offline metadata if the app is in offline mode
    // Finamp should always use the server metadata when online, if possible
    if (FinampSettingsHelper.finampSettings.isOffline) {
      DownloadedLyrics? downloadedLyrics;
        downloadedLyrics = await downloadsService.getLyricsDownload(baseItem: request.item);
        if (downloadedLyrics != null) {
          metadata.lyrics = downloadedLyrics.lyricDto;
          metadataProviderLogger.fine("Got offline lyrics for '${request.item.name}'");
        }
        else {
          metadataProviderLogger.fine("No offline lyrics for '${request.item.name}'");
        }
    } else {
      metadataProviderLogger.fine("Fetching lyrics for '${request.item.name}' (${request.item.id})");
      try {
        final lyrics = await jellyfinApiHelper.getLyrics(
          itemId: request.item.id,
        );
        metadata.lyrics = lyrics;
      } catch (e) {
        metadataProviderLogger.warning("Failed to fetch lyrics for '${request.item.name}' (${request.item.id}). Metadata might be stale", e);
      }
    }
  }

  metadataProviderLogger.fine("Fetched metadata for '${request.item.name}' (${request.item.id}): ${metadata.lyrics} ${metadata.hasLyrics}");

  return metadata;

});

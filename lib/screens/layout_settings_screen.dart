import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:hive/hive.dart';

import '../components/LayoutSettingsScreen/content_grid_view_cross_axis_count_list_tile.dart';
import '../components/LayoutSettingsScreen/content_view_type_dropdown_list_tile.dart';
import '../components/LayoutSettingsScreen/hide_song_artists_if_same_as_album_artists_selector.dart';
import '../components/LayoutSettingsScreen/show_cover_as_player_background_selector.dart';
import '../components/LayoutSettingsScreen/show_text_on_grid_view_selector.dart';
import '../components/LayoutSettingsScreen/theme_selector.dart';
import '../models/finamp_models.dart';
import '../services/finamp_settings_helper.dart';
import 'tabs_settings_screen.dart';

class LayoutSettingsScreen extends StatelessWidget {
  const LayoutSettingsScreen({Key? key}) : super(key: key);

  static const routeName = "/settings/layout";

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
        valueListenable: FinampSettingsHelper.finampSettingsListener,
        builder: (context, box, child) {
          return Scaffold(
            appBar: AppBar(
              title: Text(AppLocalizations.of(context)!.layoutAndTheme),
            ),
            body: ListView(
              children: [
                const ContentViewTypeDropdownListTile(),
                const FixedSizeGridSwitch(),
                if (!FinampSettingsHelper.finampSettings.useFixedSizeGridTiles)
                  for (final type in ContentGridViewCrossAxisCountType.values)
                    ContentGridViewCrossAxisCountListTile(type: type),
                if (FinampSettingsHelper.finampSettings.useFixedSizeGridTiles)
                  const FixedGridTileSizeDropdownListTile(),
                const ShowTextOnGridViewSelector(),
                const ShowCoverAsPlayerBackgroundSelector(),
                const HideSongArtistsIfSameAsAlbumArtistsSelector(),
                const ThemeSelector(),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.tab),
                  title: Text(AppLocalizations.of(context)!.tabs),
                  onTap: () => Navigator.of(context)
                      .pushNamed(TabsSettingsScreen.routeName),
                ),
              ],
            ),
          );
        });
  }
}

class FixedSizeGridSwitch extends StatelessWidget {
  const FixedSizeGridSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, child) {
        bool? useFixedSizeGridTiles =
            box.get("FinampSettings")?.useFixedSizeGridTiles;

        return SwitchListTile.adaptive(
          title: Text(AppLocalizations.of(context)!.fixedGridSizeSwitchTitle),
          subtitle:
              Text(AppLocalizations.of(context)!.fixedGridSizeSwitchSubtitle),
          value: useFixedSizeGridTiles ?? false,
          onChanged: useFixedSizeGridTiles == null
              ? null
              : (value) {
                  FinampSettings finampSettingsTemp =
                      box.get("FinampSettings")!;
                  finampSettingsTemp.useFixedSizeGridTiles = value;
                  box.put("FinampSettings", finampSettingsTemp);
                },
        );
      },
    );
  }
}

class FixedGridTileSizeDropdownListTile extends StatelessWidget {
  const FixedGridTileSizeDropdownListTile({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (_, box, __) {
        return ListTile(
          title: Text(AppLocalizations.of(context)!.fixedGridSizeTitle),
          trailing: DropdownButton<FixedGridTileSize>(
            value: FixedGridTileSize.fromInt(
                FinampSettingsHelper.finampSettings.fixedGridTileSize),
            items: FixedGridTileSize.values
                .map((e) => DropdownMenuItem<FixedGridTileSize>(
                      value: e,
                      child: Text(AppLocalizations.of(context)!
                          .fixedGridTileSizeEnum(e.name)),
                    ))
                .toList(),
            onChanged: (value) {
              if (value != null) {
                FinampSettings finampSettingsTemp = box.get("FinampSettings")!;
                finampSettingsTemp.fixedGridTileSize = value.toInt;
                box.put("FinampSettings", finampSettingsTemp);
              }
            },
          ),
        );
      },
    );
  }
}

enum FixedGridTileSize {
  small,
  medium,
  large,
  veryLarge;

  static FixedGridTileSize fromInt(int size) => switch (size) {
        100 => small,
        150 => medium,
        230 => large,
        360 => veryLarge,
        _ => medium
      };

  int get toInt => switch (this) {
        small => 100,
        medium => 150,
        large => 230,
        veryLarge => 360
      };
}

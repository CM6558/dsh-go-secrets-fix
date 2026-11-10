import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/plugins_state.dart';
import '../common/capsule_chip.dart';
import '../common/list_page_row.dart';
import '../common/search_capsule.dart';
import '../features/feature_kit.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'plugin_detail_sheet.dart';
import 'plugin_widgets.dart';
import 'plugins_screen.dart';

/// 「插件市场」: search, category chips and the dshfind catalogue as cards.
class MarketSliver extends ConsumerStatefulWidget {
  const MarketSliver({super.key});

  @override
  ConsumerState<MarketSliver> createState() => _MarketSliverState();
}

class _MarketSliverState extends ConsumerState<MarketSliver> {
  late final TextEditingController _search = TextEditingController(text: ref.read(marketFilterProvider).query);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) ref.read(marketFilterProvider.notifier).setQuery(text);
    });
  }

  void _clear() {
    _debounce?.cancel();
    _search.clear();
    ref.read(marketFilterProvider.notifier).setQuery('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final filter = ref.watch(marketFilterProvider);
    final catalog = ref.watch(marketCatalogProvider);

    final searchField = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: SearchCapsule(controller: _search, hint: l10n.pluginsSearch, onChanged: _onQuery, onClear: _clear),
    );

    final body = catalog.when<List<Widget>>(
      skipLoadingOnRefresh: false,
      loading: () => [SliverToBoxAdapter(child: PluginsLoading(l10n.pluginsMarketLoading))],
      error: (error, _) => [
        SliverToBoxAdapter(
          child: PluginsErrorCard(
            title: l10n.pluginsMarketLoadFailed,
            message: error is MarketFetchException ? error.message : l10n.pluginsMarketInvalid,
            onRetry: () => ref.invalidate(marketCatalogProvider),
          ),
        ),
      ],
      data: (catalog) {
        final results = filterMarket(catalog, filter);
        final hidden = hiddenWebOnlyCount(catalog, filter);
        final categories = [
          for (final c in catalog.categories)
            if (filter.showWebOnly ||
                filter.category == c.id ||
                catalog.entries.any((e) => e.plugin.category == c.id && !e.webOnly))
              c,
        ];
        return [
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                children: [
                  _CategoryChip(
                    label: l10n.pluginsAll,
                    selected: filter.category == null,
                    onSelected: () => ref.read(marketFilterProvider.notifier).setCategory(null),
                  ),
                  for (final c in categories)
                    _CategoryChip(
                      label: c.title.resolve('zh'),
                      selected: filter.category == c.id,
                      onSelected: () =>
                          ref.read(marketFilterProvider.notifier).setCategory(filter.category == c.id ? null : c.id),
                    ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.pluginsMarketCount(results.length),
                      style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                    ),
                  ),
                  if (hidden > 0 || filter.showWebOnly)
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: theme.textTheme.labelMedium,
                      ),
                      onPressed: () => ref.read(marketFilterProvider.notifier).setShowWebOnly(!filter.showWebOnly),
                      child: Text(filter.showWebOnly ? l10n.pluginsHideWeb : l10n.pluginsShowWebCount(hidden)),
                    ),
                ],
              ),
            ),
          ),
          if (results.isEmpty)
            SliverToBoxAdapter(
              child: EmptyView(
                icon: AppIcons.noResults,
                title: filter.query.trim().isEmpty
                    ? l10n.pluginsNoCategoryPlugins
                    : l10n.pluginsNoSearchResults(filter.query.trim()),
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
              ),
            )
          else
            SliverList.builder(
              itemCount: results.length,
              // One card in segments, so rows stay lazily built.
              itemBuilder: (context, i) {
                final first = i == 0;
                final last = i == results.length - 1;
                return FadeSlideIn(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Material(
                      color: DshSurfaces.of(context).card.fill,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.vertical(
                          top: first ? AppShape.radiusLg.topLeft : Radius.zero,
                          bottom: last ? AppShape.radiusLg.bottomLeft : Radius.zero,
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.only(top: first ? 4 : 0, bottom: last ? 4 : 0),
                        child: MarketCard(key: ValueKey(results[i].name), entry: results[i]),
                      ),
                    ),
                  ),
                );
              },
            ),
        ];
      },
    );

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: searchField),
        ...body,
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.selected, required this.onSelected});

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: CapsuleChoiceChip(label: label, selected: selected, onSelected: onSelected),
  );
}

/// One market entry, app-store style: icon · name / author · one line ·
/// the 获取 capsule, inside the lazily built segmented card.
class MarketCard extends ConsumerWidget {
  const MarketCard({super.key, required this.entry});

  final MarketEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final plugin = entry.plugin;
    final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
    final job = ref.watch(pluginInstallsProvider.select((jobs) => jobs[plugin.name]));
    final status = marketInstallStatus(plugin, bundles);
    final description = plugin.displayDescription();
    final failed = job != null && job.phase == PluginInstallPhase.failed ? job.failure : null;
    final line = failed != null ? l10n.pluginsFailureDetails(failed.title) : [?plugin.author, ?description].join(' · ');
    void open() => unawaited(showMarketPluginSheet(context, entry));

    return ListPageRow(
      leading: PluginAvatar(name: plugin.name, title: plugin.displayTitle(), icon: plugin.icon),
      leadingWidth: 40,
      title: plugin.displayTitle(),
      titleStyle: pluginRowTitle(context),
      badge: entry.featured ? PluginBadge(l10n.pluginsFeatured, tone: PluginBadgeTone.featured) : null,
      subtitle: line.isEmpty ? null : line,
      subtitleColor: failed != null ? colors.danger : null,
      trailing: PluginInstallButton(status: status, job: job, onPressed: open),
      onTap: open,
    );
  }
}

// Where share codes come in — `dshgo://share/…` links, the landing page's https
// links (once App Links are verified) and `.dshgo` files opened with or shared
// to the app — and the confirm sheet they open. A conversation file opens its
// replay instead (lib/ui/replay/).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../links/app_links.dart';
import '../../share_code/conversation_share.dart';
import '../../share_code/share_code_state.dart';
import '../../share_code/share_codec.dart';
import '../../share_code/share_link.dart';
import '../../share_code/share_models.dart';
import '../../share_code/share_net.dart';
import '../replay/replay_page.dart' show openConversationReplay;
import 'import_sheet.dart';

/// Short copy for a share code that can't be opened.
String shareOpenError(Object error) => switch (error) {
  ShareFormatException(reason: 'newer format') => appL10n.pluginsShareNeedsUpdate,
  ShareFormatException() => appL10n.pluginsShareUnusable,
  ShareDecodeException() => appL10n.pluginsShareDamaged,
  GistException(:final message) => message,
  FileSystemException() => appL10n.pluginsShareFileReadFailed,
  _ => appL10n.pluginsShareOpenFailed,
};

/// Opens [link]'s confirm sheet (fetching a Gist first). Errors become a
/// toast on [context]. Always true: the link was ours.
Future<bool> openShareLink(BuildContext context, ShareLink link) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final text = await fetchShareLinkText(link, container.read(shareNetProvider));
    if (!context.mounted) return true;
    await _open(context, text, origin: link.isGist ? ShareOrigin.gist : ShareOrigin.link);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(shareOpenError(e))));
  }
  return true;
}

/// Opens a `.dshgo` file's confirm sheet.
Future<bool> openShareFile(BuildContext context, File file) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    if (await file.length() > maxConversationFileBytes * 2) throw const ShareDecodeException('file too large');
    final text = await file.readAsString();
    if (!context.mounted) return true;
    await _open(context, text, origin: ShareOrigin.file);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(shareOpenError(e))));
  }
  return true;
}

/// A conversation opens its replay; anything else its confirm sheet.
Future<void> _open(BuildContext context, String fileText, {required ShareOrigin origin}) async {
  final envelope = readShareEnvelope(fileText);
  final json = decodeShareJson(envelope.code, large: true);
  if (ShareKind.parse(json['kind']) == ShareKind.conversation) {
    final share = ConversationShare.fromJson(json);
    final conversation = DecodedConversation(
      share,
      readConversationAssets(envelope.assets, share),
      code: envelope.code,
    );
    await openConversationReplay(context, conversation);
    return;
  }
  await showShareImportSheet(context, SharePayload.fromJson(json), origin: origin);
}

/// Put it once inside the home route, next to [LinkHost]. It draws nothing:
/// it registers the `share` host, the landing page and `.dshgo` files with
/// the link router.
class ShareCodeHost extends ConsumerStatefulWidget {
  const ShareCodeHost({super.key});

  @override
  ConsumerState<ShareCodeHost> createState() => _ShareCodeHostState();
}

class _ShareCodeHostState extends ConsumerState<ShareCodeHost> {
  final _off = <VoidCallback>[];

  @override
  void initState() {
    super.initState();
    final router = ref.read(linkRouterProvider);
    _off
      ..add(router.registerLinkHandler(shareLinkHost, _link))
      ..add(router.registerLinkHandler(shareLandingRoute, _link))
      ..add(router.registerFileHandler(shareFileExtension, _file));
  }

  BuildContext? get _ui {
    final routed = ref.read(linkRouterProvider).context;
    if (routed != null) return routed;
    return mounted ? context : null;
  }

  Future<bool> _link(Uri uri) async {
    final link = ShareLink.parse(uri);
    final ui = _ui;
    if (link == null || ui == null) return false;
    return openShareLink(ui, link);
  }

  Future<bool> _file(Uri uri) async {
    final ui = _ui;
    if (ui == null) return false;
    return openShareFile(ui, File(uri.toFilePath()));
  }

  @override
  void dispose() {
    for (final off in _off) {
      off();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

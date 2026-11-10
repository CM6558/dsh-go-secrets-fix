import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/l10n.dart';
import 'connection_state.dart';

/// Something picked in the composer and not sent yet.
///
/// Images DSH takes inline (png, jpeg, webp, gif) ride in the prompt itself;
/// anything else is staged first with `fileUploads/upload` and referenced by
/// its receipt. Which one is decided from the bytes, not the file name.
class DraftAttachment {
  DraftAttachment({required this.name, required this.bytes, this.mediaType}) : id = _nextId++;

  factory DraftAttachment.sniff(String name, Uint8List bytes) =>
      DraftAttachment(name: name, bytes: bytes, mediaType: inlineImageType(bytes));

  static int _nextId = 0;

  /// Stable within the app run; keys the tray and the optimistic bubble.
  final int id;
  final String name;
  final Uint8List bytes;

  /// Set for inline images; null for files.
  final String? mediaType;

  bool get isImage => mediaType != null;
  int get size => bytes.length;
}

/// Valid file picks plus the first rejected item, so one large file does not
/// discard the rest of a multi-selection.
class PickedAttachments {
  const PickedAttachments(this.attachments, {this.problem});

  final List<DraftAttachment> attachments;
  final String? problem;
}

/// DSH's inline image limit (`SessionProjections.imageLimits` default).
const maxImageBytes = 20 * 1024 * 1024;

/// Files travel base64 inside one RPC frame; keep them to what a phone can
/// hold twice over without trouble.
const maxFileBytes = 30 * 1024 * 1024;

/// At most this many attachments per message (DSH allows 20 images).
const maxAttachments = 9;

/// Media type when [bytes] is an image DSH accepts inline, else null.
String? inlineImageType(Uint8List bytes) {
  bool at(int offset, List<int> sig) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) && at(8, const [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  return null;
}

/// "1.2 MB", "860 KB", "12 B".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}

/// Why [a] can't be attached, or null when it can.
String? attachmentProblem(DraftAttachment a) {
  if (a.size == 0) return appL10n.stateAttachmentEmpty(a.name);
  if (a.isImage && a.size > maxImageBytes) {
    return appL10n.stateAttachmentImageLimit(a.name);
  }
  if (!a.isImage && a.size > maxFileBytes) {
    return appL10n.stateAttachmentFileLimit(a.name);
  }
  return null;
}

/// The system pickers behind the composer's ＋ menu. Tests swap in a fake.
abstract class AttachmentPicker {
  Future<List<DraftAttachment>> pickImages({required int limit});
  Future<DraftAttachment?> takePhoto();
  Future<PickedAttachments> pickFiles({int limit = maxAttachments});

  /// A small text file (an SSH private key); null when cancelled.
  Future<String?> pickTextFile({int maxBytes = 64 * 1024});
}

class DeviceAttachmentPicker implements AttachmentPicker {
  const DeviceAttachmentPicker();

  // Phone photos are 12–50 MP; the model gains nothing past ~2.5k on the long
  // side and the upload shrinks tenfold. Re-encoding also turns HEIC into JPEG.
  static const _maxSide = 2560.0;
  static const _quality = 88;

  @override
  Future<List<DraftAttachment>> pickImages({required int limit}) async {
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: _maxSide,
      maxHeight: _maxSide,
      imageQuality: _quality,
      limit: limit,
      // No location/EXIF access needed: skips the media-location permission.
      requestFullMetadata: false,
    );
    return [for (final x in picked.take(limit)) DraftAttachment.sniff(x.name, await x.readAsBytes())];
  }

  @override
  Future<DraftAttachment?> takePhoto() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: _maxSide,
      maxHeight: _maxSide,
      imageQuality: _quality,
      requestFullMetadata: false,
    );
    if (x == null) return null;
    return DraftAttachment.sniff(x.name, await x.readAsBytes());
  }

  @override
  Future<PickedAttachments> pickFiles({int limit = maxAttachments}) async {
    final picked = await FilePicker.pickFiles();
    final accepted = <DraftAttachment>[];
    String? problem;
    for (final file in picked) {
      if (accepted.length >= limit) {
        problem ??= appL10n.chatAttachmentLimit(maxAttachments);
        break;
      }
      // Metadata can reject an oversized file without opening it, but cannot
      // authorize a read: content providers may omit it or report a stale size.
      final length = file.lengthSync();
      if (length != null && length > maxFileBytes) {
        problem ??= appL10n.stateAttachmentFileLimit(file.name);
        continue;
      }
      final bytes = BytesBuilder(copy: false);
      final prefix = Uint8List(12);
      var prefixLength = 0;
      String? mediaType;
      var tooLarge = false;
      await for (final chunk in file.readAsByteStream()) {
        // Signatures may span chunks. Inspect only the small prefix before
        // retaining a chunk, and use image limits even with a misleading name.
        final take = (prefix.length - prefixLength).clamp(0, chunk.length);
        prefix.setRange(prefixLength, prefixLength + take, chunk);
        prefixLength += take;
        mediaType = inlineImageType(Uint8List.sublistView(prefix, 0, prefixLength));
        final budget = mediaType == null ? maxFileBytes : maxImageBytes;
        if ((length != null && length > budget) || chunk.length > budget - bytes.length) {
          tooLarge = true;
          break; // Cancels the stream without retaining the excess chunk.
        }
        bytes.add(chunk);
      }
      if (tooLarge) {
        problem ??= mediaType == null
            ? appL10n.stateAttachmentFileLimit(file.name)
            : appL10n.stateAttachmentImageLimit(file.name);
        continue;
      }
      final attachment = DraftAttachment(name: file.name, bytes: bytes.takeBytes(), mediaType: mediaType);
      final issue = attachmentProblem(attachment);
      if (issue != null) {
        problem ??= issue;
      } else {
        accepted.add(attachment);
      }
    }
    return PickedAttachments(accepted, problem: problem);
  }

  @override
  Future<String?> pickTextFile({int maxBytes = 64 * 1024}) async {
    final f = await FilePicker.pickFile();
    if (f == null) return null;
    // Picker metadata can be absent or stale. It is only an early rejection;
    // enforce the byte budget on the stream before retaining each chunk.
    final length = f.lengthSync();
    if (length != null && length > maxBytes) {
      throw FormatException(appL10n.statePrivateKeyTooLarge);
    }
    final bytes = BytesBuilder();
    await for (final chunk in f.readAsByteStream()) {
      if (chunk.length > maxBytes - bytes.length) {
        // Leaving await-for cancels the source instead of reading the tail.
        throw FormatException(appL10n.statePrivateKeyTooLarge);
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}

final attachmentPickerProvider = Provider<AttachmentPicker>((ref) => const DeviceAttachmentPicker());

/// Bytes of an image a session's log refers to (`session/attachment`), for
/// thumbnails of sent messages. Dropped once no bubble shows it.
final sessionImageProvider = FutureProvider.autoDispose.family<Uint8List, (String, String)>((ref, key) async {
  final (sessionId, attachmentId) = key;
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null) throw StateError(appL10n.commonNotConnected);
  // Scrolling a bubble out and back shouldn't refetch; let it go a bit later.
  final link = ref.keepAlive();
  Timer? release;
  ref.onCancel(() => release = Timer(const Duration(seconds: 30), link.close));
  ref.onResume(() => release?.cancel());
  ref.onDispose(() => release?.cancel());
  return (await client.attachment(sessionId, attachmentId)).bytes;
});

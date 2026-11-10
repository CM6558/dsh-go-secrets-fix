// What a host can generate with (docs/design/media-generation.md §4.3,
// §4.6.5; the dsh-media plugin's MEDIA-CATALOG-CONTRACT): its model catalogue
// crossed with the services really configured there.
//
// The catalogue is metadata, not a setting: settings/describe carries it on
// the plugin's `services` field, `meta.extra["dsh-go/media/catalog"]`, under
// whatever namespace the host gave the plugin. A catalogue that is missing,
// damaged or of an unknown version gives no generation mode (ordinary chat
// still works); there is no built-in model table to fall back on. A model is
// on offer only through a service that is switched on, whose key the host
// says is there, that lists it — and only when the parameter header can name
// it exactly (§4.6.1).
//
// Pure: no providers here, so the engine settings can ask which keys to read.

import 'package:dsh_client/dsh_client.dart';

import '../ui/chat/media/generate_header.dart';

/// The metadata key the catalogue sits under.
const mediaCatalogMetaKey = 'dsh-go/media/catalog';

/// The catalogue contract this app reads.
const mediaCatalogContract = 'dsh-go/media/catalog';
const mediaCatalogVersion = 1;

enum MediaCatalogStatus {
  /// Settings not read yet.
  loading,

  /// No namespace carries a catalogue.
  missing,

  /// A catalogue of another version or contract.
  unsupported,

  /// A catalogue this app can't read.
  broken,

  /// Read; [MediaCatalog.entries] says what can generate (maybe nothing yet).
  ready,
}

/// A model's price as the catalogue gives it.
class MediaPrice {
  const MediaPrice({required this.perSecond, required this.amount, this.currency = 'CNY'});

  final bool perSecond;
  final double amount;
  final String currency;
}

/// One model of the catalogue (§4.3), with only the values a header can
/// carry.
class MediaModel {
  const MediaModel({
    required this.id,
    required this.label,
    required this.kind,
    this.profile,
    this.ratios = const [],
    this.qualities = const [],
    this.maxN = 1,
    this.durations = const [],
    this.resolutions = const [],
    this.maxRefs = 0,
    this.firstFrame = false,
    this.lastFrame = false,
    this.edit = false,
    this.price,
  });

  final String id;
  final String label;
  final GenerateKind kind;

  /// The request protocol a service must speak to serve it.
  final String? profile;

  /// `1:1`, `3:2`… Empty: the aspect is the host's to choose.
  final List<String> ratios;

  /// The catalogue's own values: `1k`, `2k`, `high`… (image).
  final List<String> qualities;

  /// Pictures at once, 1–4, already within every limit.
  final int maxN;

  /// Seconds the model allows (video).
  final List<int> durations;

  /// `720p`, `1080p` (video).
  final List<String> resolutions;
  final int maxRefs;
  final bool firstFrame;
  final bool lastFrame;
  final bool edit;
  final MediaPrice? price;

  MediaModel _limitedTo(int? limit) => limit == null || limit >= maxN
      ? this
      : MediaModel(
          id: id,
          label: label,
          kind: kind,
          profile: profile,
          ratios: ratios,
          qualities: qualities,
          maxN: limit < 1 ? 1 : limit,
          durations: durations,
          resolutions: resolutions,
          maxRefs: maxRefs,
          firstFrame: firstFrame,
          lastFrame: lastFrame,
          edit: edit,
          price: price,
        );
}

/// One configured service of the plugin (`value.services[]`).
class MediaService {
  const MediaService({required this.id, this.label = '', this.provider});

  final String id;
  final String label;
  final String? provider;

  /// What the model page groups under.
  String get title => label.isNotEmpty ? label : id;
}

/// Which model a mode means: where it is (namespace, service, model id) and
/// its name. Without [service] and [id] it is only a name the app could not
/// pin to one choice; the person picks again.
class MediaModelRef {
  const MediaModelRef({this.namespace, this.service, this.id, required this.label});

  static MediaModelRef? fromJson(Object? json) {
    if (json is! Map) return null;
    String? read(String key) => json[key] is String && (json[key] as String).isNotEmpty ? json[key] as String : null;
    final label = json['label'];
    if (label is! String) return null;
    return MediaModelRef(namespace: read('ns'), service: read('service'), id: read('id'), label: label);
  }

  final String? namespace;
  final String? service;
  final String? id;
  final String label;

  bool get pinned => service != null && id != null;

  /// The header's model field.
  GenerateModelTag get tag => GenerateModelTag(label, service: pinned ? service : null, id: pinned ? id : null);

  Map<String, Object?> toJson() => {'ns': ?namespace, 'service': ?service, 'id': ?id, 'label': label};

  @override
  bool operator ==(Object other) =>
      other is MediaModelRef &&
      other.namespace == namespace &&
      other.service == service &&
      other.id == id &&
      other.label == label;

  @override
  int get hashCode => Object.hash(namespace, service, id, label);

  @override
  String toString() => '$namespace/$service/$id ($label)';
}

/// One choice: a model through one service of one plugin namespace.
class MediaEntry {
  const MediaEntry({required this.namespace, required this.service, required this.model});

  final String namespace;
  final MediaService service;
  final MediaModel model;

  GenerateKind get kind => model.kind;

  MediaModelRef get ref => MediaModelRef(namespace: namespace, service: service.id, id: model.id, label: model.label);

  /// Unique across the catalogue.
  String get key => '$namespace\u0000${service.id}\u0000${model.id}';
}

/// What the current host offers.
class MediaCatalog {
  const MediaCatalog({this.status = MediaCatalogStatus.ready, this.entries = const [], this.defaults = const []});

  static const loading = MediaCatalog(status: MediaCatalogStatus.loading);
  static const missing = MediaCatalog(status: MediaCatalogStatus.missing);

  final MediaCatalogStatus status;

  /// In the host's order: namespace, then service, then the service's list.
  final List<MediaEntry> entries;

  /// Each namespace's `value.defaults`, in the host's order.
  final List<({String namespace, String service, String model})> defaults;

  /// A catalogue this app can read: generation mode is possible here.
  bool get usable => status == MediaCatalogStatus.ready;

  /// Something to generate with right now.
  bool get configured => usable && entries.isNotEmpty;

  /// The kinds with at least one choice, image first.
  List<GenerateKind> get kinds => [
    for (final kind in GenerateKind.values)
      if (entries.any((e) => e.kind == kind)) kind,
  ];

  List<MediaEntry> of(GenerateKind kind) => [
    for (final e in entries)
      if (e.kind == kind) e,
  ];

  /// The one choice [ref] pins, of [kind]; null when it pins none (a bare
  /// name, a service since switched off).
  MediaEntry? resolve(MediaModelRef? ref, GenerateKind kind) {
    if (ref == null || !ref.pinned) return null;
    final found = [
      for (final e in of(kind))
        if (e.service.id == ref.service &&
            e.model.id == ref.id &&
            (ref.namespace == null || e.namespace == ref.namespace))
          e,
    ];
    return found.length == 1 ? found.single : null;
  }

  /// A header's model as a mode's (§4.6.5): by its marker, else by a name only
  /// one choice of [kind] has. Anything else stays an unpinned name.
  MediaModelRef refOfTag(GenerateModelTag tag, GenerateKind kind) {
    final found = [
      for (final e in of(kind))
        if (tag.marked ? e.service.id == tag.service && e.model.id == tag.id : e.model.label == tag.label) e,
    ];
    return found.length == 1 ? found.single.ref : MediaModelRef(label: tag.label);
  }

  /// A card's request as a mode's model: the tool result names the provider
  /// and the model, not the service, so it pins only when one choice fits.
  MediaModelRef? refOfRequest(MediaRequestInfo request, GenerateKind kind) {
    final id = request.model;
    final label = request.label;
    if (id == null && label == null) return null;
    final found = [
      for (final e in of(kind))
        if (id != null
            ? e.model.id == id && (request.provider == null || e.service.provider == request.provider)
            : e.model.label == label)
          e,
    ];
    return found.length == 1 ? found.single.ref : MediaModelRef(label: label ?? id!);
  }

  /// What a fresh mode of [kind] starts on: the plugin's default when it is
  /// on offer, else the first choice.
  MediaEntry? defaultFor(GenerateKind kind) {
    final choices = of(kind);
    for (final d in defaults) {
      if (d.service.isEmpty) continue;
      final match = choices.where(
        (e) => e.namespace == d.namespace && e.service.id == d.service && (d.model.isEmpty || e.model.id == d.model),
      );
      if (match.isNotEmpty) return match.first;
    }
    return choices.firstOrNull;
  }
}

// ── Reading settings/describe ────────────────────────────────────────────────

/// The catalogue [view] carries, as sent; null when it carries none.
Object? mediaCatalogMetaOf(SettingsNamespaceView view) {
  final services = view.schema.fields?['services'];
  if (services == null) return null;
  // On the field itself (a transform): its effective array may not carry it.
  for (final node in [services, services.effective]) {
    final extra = node.meta.extra;
    if (extra is Map && extra.containsKey(mediaCatalogMetaKey)) return extra[mediaCatalogMetaKey];
  }
  return null;
}

/// Namespaces that carry a catalogue, in the host's order.
List<String> mediaNamespacesOf(Map<String, SettingsNamespaceView> namespaces) => [
  for (final view in namespaces.values)
    if (mediaCatalogMetaOf(view) != null) view.ns,
];

/// The credential references the plugin's services name: the engine
/// settings read them with the rest, so [mediaCatalogFrom] knows which keys
/// are there.
Set<String> mediaKeyRefsOf(Map<String, SettingsNamespaceView> namespaces) => {
  for (final view in namespaces.values)
    if (mediaCatalogMetaOf(view) != null)
      for (final service in _list(view.value['services']))
        if (service is Map && service['keyRef'] is String && (service['keyRef'] as String).isNotEmpty)
          service['keyRef'] as String,
};

/// [namespaces] (null: not read yet) as what can generate, given which
/// [credentials] the host says are set.
MediaCatalog mediaCatalogFrom(
  Map<String, SettingsNamespaceView>? namespaces, {
  Map<String, CredentialStatus> credentials = const {},
}) {
  if (namespaces == null) return MediaCatalog.loading;
  final read = <(SettingsNamespaceView, _Catalog)>[];
  var found = false;
  var unsupported = false;
  for (final view in namespaces.values) {
    final raw = mediaCatalogMetaOf(view);
    if (raw == null) continue;
    found = true;
    try {
      read.add((view, _Catalog.parse(raw)));
    } on _Unsupported {
      unsupported = true;
    } on _Broken {
      // Counted below: found, but nothing read.
    }
  }
  if (!found) return MediaCatalog.missing;
  if (read.isEmpty) {
    return MediaCatalog(status: unsupported ? MediaCatalogStatus.unsupported : MediaCatalogStatus.broken);
  }

  final entries = <MediaEntry>[];
  final defaults = <({String namespace, String service, String model})>[];
  for (final (view, catalog) in read) {
    entries.addAll(catalog.entriesFor(view, credentials));
    final d = view.value['defaults'];
    if (d is Map) {
      defaults.add((
        namespace: view.ns,
        service: d['serviceId'] is String ? d['serviceId'] as String : '',
        model: d['modelId'] is String ? d['modelId'] as String : '',
      ));
    }
  }
  // v1's header names no namespace: a service and model two namespaces share
  // can't be told apart, so neither is offered (§4.6.5).
  final seen = <String, int>{};
  for (final e in entries) {
    final key = '${e.service.id}\u0000${e.model.id}';
    seen[key] = (seen[key] ?? 0) + 1;
  }
  return MediaCatalog(
    entries: List.unmodifiable([
      for (final e in entries)
        if (seen['${e.service.id}\u0000${e.model.id}'] == 1) e,
    ]),
    defaults: List.unmodifiable(defaults),
  );
}

class _Broken implements Exception {}

class _Unsupported implements Exception {}

List<Object?> _list(Object? value) => value is List ? value : const [];

final _serviceId = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
final _aspect = RegExp(r'^[1-9]\d?:[1-9]\d?$');
final _quality = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$');
final _resolution = RegExp(r'^[1-9]\d{2,3}p$');

/// One namespace's catalogue, checked.
class _Catalog {
  _Catalog(this.models, this.kinds, this.maxN);

  /// By id; unknown kinds already dropped.
  final Map<String, MediaModel> models;

  /// Kinds `capabilities` doesn't turn off.
  final Set<GenerateKind> kinds;

  /// `limits.maxN`.
  final int? maxN;

  static _Catalog parse(Object? raw) {
    if (raw is! Map) throw _Broken();
    final v = raw['v'];
    if (v is! int) throw _Broken();
    if (v != mediaCatalogVersion) throw _Unsupported();
    final contract = raw['contract'];
    if (contract != null && contract != mediaCatalogContract) throw _Unsupported();
    final list = raw['models'];
    if (list is! List) throw _Broken();
    final caps = raw['capabilities'];
    if (caps != null && caps is! Map) throw _Broken();
    final limits = raw['limits'];
    if (limits != null && limits is! Map) throw _Broken();
    final limit = limits is Map ? limits['maxN'] : null;
    if (limit != null && limit is! int) throw _Broken();

    final ids = <String>{};
    final models = <String, MediaModel>{};
    for (final m in list) {
      if (m is! Map) throw _Broken();
      final id = m['id'];
      final label = m['label'];
      final kind = m['kind'];
      if (id is! String || id.isEmpty || !ids.add(id) || label is! String || label.isEmpty || kind is! String) {
        throw _Broken();
      }
      final known = switch (kind) {
        'image' => GenerateKind.image,
        'video' => GenerateKind.video,
        _ => null,
      };
      // A kind of a later version: left for a later app.
      if (known == null) continue;
      models[id] = _model(m, id, label, known);
    }
    bool off(String name) => caps is Map && caps.containsKey(name) && caps[name] != true;
    return _Catalog(models, {
      if (!off('image')) GenerateKind.image,
      if (!off('video')) GenerateKind.video,
    }, limit as int?);
  }

  static MediaModel _model(Map<Object?, Object?> m, String id, String label, GenerateKind kind) {
    List<String> strings(String key, RegExp keep) {
      final v = m[key];
      if (v == null) return const [];
      if (v is! List || v.any((e) => e is! String)) throw _Broken();
      // Values the header can't carry are not offered (§4.6.4).
      return List.unmodifiable({
        for (final e in v.cast<String>())
          if (keep.hasMatch(e)) e,
      });
    }

    int? integer(String key) {
      final v = m[key];
      if (v == null) return null;
      if (v is! int) throw _Broken();
      return v;
    }

    bool flag(Object? v) {
      if (v == null) return false;
      if (v is! bool) throw _Broken();
      return v;
    }

    final durations = m['durations'];
    if (durations != null && (durations is! List || durations.any((e) => e is! num))) throw _Broken();
    final frames = m['frames'];
    if (frames != null && frames is! Map) throw _Broken();
    final profile = m['profile'];
    if (profile != null && profile is! String) throw _Broken();
    final maxN = integer('maxN') ?? 1;
    return MediaModel(
      id: id,
      label: label,
      kind: kind,
      profile: profile as String?,
      ratios: strings('ratios', _aspect),
      qualities: strings('qualities', _quality),
      maxN: maxN.clamp(1, 4),
      durations: List.unmodifiable({
        for (final e in _list(durations).cast<num>())
          if (e == e.roundToDouble() && e >= 1 && e <= 60) e.toInt(),
      }),
      resolutions: strings('resolutions', _resolution),
      maxRefs: (integer('maxRefs') ?? 0).clamp(0, 99),
      firstFrame: frames is Map && flag(frames['first']),
      lastFrame: frames is Map && flag(frames['last']),
      edit: flag(m['edit']),
      price: _price(m['price']),
    );
  }

  static MediaPrice? _price(Object? json) {
    if (json is! Map) return null;
    final amount = json['amount'];
    if (amount is! num || amount < 0) return null;
    final currency = json['currency'];
    return MediaPrice(
      perSecond: json['unit'] == 'second',
      amount: amount.toDouble(),
      currency: currency is String ? currency : 'CNY',
    );
  }

  /// The choices [view]'s services make of this catalogue.
  List<MediaEntry> entriesFor(SettingsNamespaceView view, Map<String, CredentialStatus> credentials) {
    final services = _list(view.value['services']);
    final count = <String, int>{};
    for (final s in services) {
      if (s is Map && s['id'] is String) count[s['id'] as String] = (count[s['id'] as String] ?? 0) + 1;
    }
    final hostLimit = switch (view.value['limits']) {
      final Map limits when limits['maxImages'] is int => limits['maxImages'] as int,
      _ => null,
    };
    final out = <MediaEntry>[];
    for (final s in services) {
      if (s is! Map) continue;
      final id = s['id'];
      final keyRef = s['keyRef'];
      if (id is! String || !_serviceId.hasMatch(id) || count[id] != 1) continue;
      if (s['enabled'] != true) continue;
      if (keyRef is! String || credentials[keyRef]?.configured != true) continue;
      final listed = switch (s['models']) {
        final String text => text.split(','),
        final List list => [
          for (final e in list)
            if (e is String) e,
        ],
        _ => const <String>[],
      };
      final service = MediaService(
        id: id,
        label: s['label'] is String ? (s['label'] as String).trim() : '',
        provider: s['provider'] is String ? s['provider'] as String : null,
      );
      final profile = s['profile'] is String ? s['profile'] as String : null;
      final taken = <String>{};
      for (final raw in listed) {
        final modelId = raw.trim();
        final model = models[modelId];
        if (model == null || !taken.add(modelId) || !kinds.contains(model.kind)) continue;
        if (model.profile != null && profile != null && model.profile != profile) continue;
        // Only what a header can name exactly (§4.6.5).
        if (!GenerateModelTag.markable(id, model.id) || !GenerateModelTag.expressible(model.label)) continue;
        final limits = [?maxN, ?hostLimit];
        final limited = limits.isEmpty ? model : model._limitedTo(limits.reduce((a, b) => a < b ? a : b));
        out.add(MediaEntry(namespace: view.ns, service: service, model: limited));
      }
    }
    return out;
  }
}

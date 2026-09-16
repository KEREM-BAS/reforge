import 'package:meta/meta.dart';

/// Where a piece of compatibility knowledge comes from.
@immutable
final class KnowledgeSource {
  const KnowledgeSource({required this.title, required this.url, this.retrieved});

  final String title;
  final String url;

  /// When the source was consulted (ISO date), for sources that change over
  /// time such as documentation pages.
  final String? retrieved;

  Map<String, Object?> toJson() => {
        'title': title,
        'url': url,
        if (retrieved != null) 'retrieved': retrieved,
      };

  @override
  String toString() => '$title <$url>';
}

/// A value backed by a source.
@immutable
final class Fact<T> {
  const Fact(this.value, this.source);

  final T value;
  final KnowledgeSource source;
}

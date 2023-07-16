import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Search Results Model
@immutable
class SearchResults {
  const SearchResults({
    required this.packages,
    this.next,
  });

  factory SearchResults.fromMap(Map<String, dynamic> map) {
    final packagesMap = map['packages'] as List<dynamic>? ?? [];
    return SearchResults(
      packages: List<PackageResult>.from(
        packagesMap.map(
          (x) => PackageResult.fromMap(x as Map<String, dynamic>),
        ),
      ),
      next: map['next'] as String?,
    );
  }
  final List<PackageResult> packages;
  final String? next;

  Map<String, dynamic> toMap() => {
        'packages': packages.map((x) => x.toMap()).toList(),
        'next': next,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    final listEquals = const DeepCollectionEquality().equals;

    return other is SearchResults &&
        listEquals(other.packages, packages) &&
        other.next == next;
  }

  @override
  int get hashCode => packages.hashCode ^ next.hashCode;
}

/// Package Result Model returns within a `SearchResult`
@immutable
class PackageResult {
  const PackageResult({required this.package});

  factory PackageResult.fromMap(Map<String, dynamic> map) => PackageResult(
        package: map['package'] as String? ?? '',
      );
  final String package;

  Map<String, dynamic> toMap() => {
        'package': package,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PackageResult && other.package == package;
  }

  @override
  int get hashCode => package.hashCode;
}

/// Package like

class PackageLike {
  const PackageLike({
    required this.package,
    required this.liked,
  });

  factory PackageLike.fromMap(Map<String, dynamic> map) => PackageLike(
        package: map['package'] as String? ?? '',
        liked: map['liked'] as bool? ?? false,
      );
  final String package;
  final bool liked;

  Map<String, dynamic> toMap() => {
        'package': package,
        'liked': liked,
      };
}

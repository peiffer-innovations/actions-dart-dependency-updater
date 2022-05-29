class Dependency {
  Dependency({
    required this.newVersion,
    required this.oldVersion,
    required this.package,
  });

  final String newVersion;
  final String oldVersion;
  final String package;
}

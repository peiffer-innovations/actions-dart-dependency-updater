/// Package Publisher Model

class PackagePublisher {
  const PackagePublisher({
    this.publisherId,
  });

  factory PackagePublisher.fromMap(Map<String, dynamic> map) =>
      PackagePublisher(
        publisherId: map['publisherId'] as String?,
      );
  final String? publisherId;

  Map<String, dynamic> toMap() => {
        'publisherId': publisherId,
      };
}

class NetworkConnectionSnapshot {
  const NetworkConnectionSnapshot({this.key, this.sequence = initialSequence,
      this.authenticated = false, this.reconnecting = false});

  static const initialSequence = 0;
  final Object? key;
  final int sequence;
  final bool authenticated;
  final bool reconnecting;
}

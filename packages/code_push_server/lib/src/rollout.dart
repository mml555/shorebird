import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Deterministic rollout bucket in [0, 10000) for a client, derived from a
/// stable hash of (app, channel, patch, client). The same client always lands
/// in the same bucket for a given promotion, so a partial rollout is consistent
/// across requests.
int rolloutBucket(String appId, int channelId, int patchId, String clientId) {
  final d = sha256
      .convert(utf8.encode('$appId:$channelId:$patchId:$clientId'))
      .bytes;
  final n = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
  return (n & 0x7fffffff) % 10000;
}

/// Whether a client is eligible for a patch at [rollout] percent (0..100).
/// Fails closed: a partial rollout with no stable [clientId] is never eligible.
bool eligibleForRollout({
  required String appId,
  required int channelId,
  required int patchId,
  required int rollout,
  required String? clientId,
}) {
  if (rollout >= 100) return true;
  if (rollout <= 0) return false;
  if (clientId == null || clientId.isEmpty) return false;
  return rolloutBucket(appId, channelId, patchId, clientId) < rollout * 100;
}

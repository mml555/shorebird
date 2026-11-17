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
}) => eligibleForRolloutBps(
  appId: appId,
  channelId: channelId,
  patchId: patchId,
  rolloutBps: rollout * 100,
  clientId: clientId,
);

/// Whether a client is eligible for a patch rolled out to [rolloutBps] basis
/// points (hundredths of a percent, 0 to 10000) of a channel's devices.
///
/// The bucket is already in basis points, so a rollout of `p` percent is
/// `bucket < p * 100` exactly as before; fractional percentages such as 12.5
/// only add resolution. Raising a rollout never removes a device: the buckets
/// below the old threshold are below the new one.
bool eligibleForRolloutBps({
  required String appId,
  required int channelId,
  required int patchId,
  required int rolloutBps,
  required String? clientId,
}) {
  if (rolloutBps >= 10000) return true;
  if (rolloutBps <= 0) return false;
  if (clientId == null || clientId.isEmpty) return false;
  return rolloutBucket(appId, channelId, patchId, clientId) < rolloutBps;
}

/// The rollout of a `channel_patches` row, in basis points.
///
/// `rollout_bps` is the truth, written together with `rollout` (whole percent,
/// rounded down). A row whose `rollout_bps` is missing, or disagrees with
/// `rollout`, was written by a server that predates the column (a rolling
/// upgrade, or a rollback of the binary), and `rollout` is then the one that
/// was kept current.
int effectiveRolloutBps(Map<String, Object?> row) {
  final whole = (row['rollout'] as num).toInt();
  final bps = row['rollout_bps'];
  if (bps is num && bps.toInt() ~/ 100 == whole) return bps.toInt();
  return whole * 100;
}

/// [bps] as a percentage in the JSON a client reads: an integer when it is a
/// whole percentage, so what the API sent before fractional rollouts reads the
/// same, and a double otherwise.
num percentageOf(int bps) => bps % 100 == 0 ? bps ~/ 100 : bps / 100;

/// Parses a rollout percentage from a request body: a number from 0.01 to 100
/// that is a multiple of 0.01, as the CLI's `--rollout` is. Returns basis
/// points. Throws [FormatException] naming the problem.
int parseRolloutPercentage(Object? value, {required String field}) {
  if (value is! num || !value.isFinite) {
    throw FormatException('$field must be a number');
  }
  final bps = (value * 100).round();
  if ((value * 100 - bps).abs() > 1e-6) {
    throw FormatException('$field must be a multiple of 0.01');
  }
  if (bps < 1 || bps > 10000) {
    throw FormatException('$field must be between 0.01 and 100');
  }
  return bps;
}

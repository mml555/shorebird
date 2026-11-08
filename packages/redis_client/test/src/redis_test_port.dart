import 'dart:io';

/// The port of the Redis server the tests talk to.
///
/// CI starts Redis on a free host port, since the runner host is shared, and
/// passes it in `REDIS_PORT`. Without it the tests use Redis's own default,
/// 6379, as in CONTRIBUTING.md.
final int redisTestPort =
    int.tryParse(Platform.environment['REDIS_PORT'] ?? '') ?? 6379;

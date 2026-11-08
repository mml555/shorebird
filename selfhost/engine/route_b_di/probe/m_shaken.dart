// IMPORT_RESOLUTION: calls a host function that is neither retained by the
// dynamic interface nor referenced by the host, so AOT drops it.
import 'package:dynamic_modules/n_host.dart';

@pragma('dyn-module:entry-point')
Object? entry() => shakenAway();

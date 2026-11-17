# Counter release vs kept release, per key

Rows: verdict in the counter release. Columns: verdict in the kept release. Counts are keys.

| counter \ kept | SAFE | UNCALLED | THROWS | CRASH | CRASH(host) | PARTIAL | total |
|---|---|---|---|---|---|---|---|
| SAFE | 112 | 0 | 0 | 0 | 0 | 0 | 112 |
| UNCALLED | 3 | 21 | 0 | 0 | 0 | 0 | 24 |
| THROWS | 120 | 21 | 40 | 43 | 0 | 0 | 224 |
| CRASH | 7 | 2 | 0 | 46 | 0 | 0 | 55 |
| CRASH(host) | 0 | 0 | 0 | 1 | 3 | 0 | 4 |
| PARTIAL | 0 | 0 | 0 | 0 | 0 | 7 | 7 |

## THROWS in the counter release, SAFE in the kept release (120)

- `dart:async#Stream#get:first`: kept by call sites and --sdk-members
- `dart:async#Stream#get:isBroadcast`: kept by --sdk-members
- `dart:async#Stream#listen`: kept by call sites and --sdk-members
- `dart:async#Stream#map`: kept by call sites and --sdk-members
- `dart:async#Stream#tearoff:map`: kept by call sites and --sdk-members
- `dart:async#Stream#tearoff:toList`: kept by call sites and --sdk-members
- `dart:async#Stream#tearoff:where`: kept by call sites and --sdk-members
- `dart:async#Stream#toList`: kept by call sites and --sdk-members
- `dart:async#Stream#where`: kept by call sites and --sdk-members
- `dart:async#StreamController#get:sink`: kept by --sdk-members
- `dart:async#Timer#get:isActive`: kept by --sdk-members (thin)
- `dart:async#Timer#get:tick`: kept by --sdk-members (thin)
- `dart:core#DateTime#add`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#difference`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#get:microsecondsSinceEpoch`: kept by --sdk-members (thin)
- `dart:core#DateTime#get:month`: kept by --sdk-members (thin)
- `dart:core#DateTime#get:weekday`: kept by --sdk-members (thin)
- `dart:core#DateTime#get:year`: kept by --sdk-members (thin)
- `dart:core#DateTime#isAfter`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#isBefore`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#subtract`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#tearoff:add`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#tearoff:difference`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#tearoff:isAfter`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#tearoff:isBefore`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#tearoff:subtract`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#tearoff:toIso8601String`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#tearoff:toUtc`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#toIso8601String`: kept by call sites and --sdk-members (thin)
- `dart:core#DateTime#toUtc`: kept by call sites and --sdk-members (thin)
- `dart:core#Duration#>`: kept by --sdk-members (thin)
- `dart:core#Duration#get:inMilliseconds`: kept by --sdk-members (thin)
- `dart:core#Duration#get:inMinutes`: kept by --sdk-members (thin)
- `dart:core#Duration#get:inSeconds`: kept by --sdk-members (thin)
- `dart:core#Duration#get:isNegative`: kept by --sdk-members (thin)
- `dart:core#Iterable#elementAt`: kept by call sites and --sdk-members
- `dart:core#Iterable#firstWhere`: kept by call sites and --sdk-members
- `dart:core#Iterable#fold`: kept by call sites and --sdk-members
- `dart:core#Iterable#join`: kept by call sites and --sdk-members
- `dart:core#Iterable#map`: kept by call sites and --sdk-members
- `dart:core#Iterable#reduce`: kept by call sites and --sdk-members
- `dart:core#Iterable#skip`: kept by call sites and --sdk-members
- `dart:core#Iterable#take`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:contains`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:elementAt`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:every`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:firstWhere`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:fold`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:join`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:map`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:reduce`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:skip`: kept by call sites and --sdk-members
- `dart:core#Iterable#tearoff:take`: kept by call sites and --sdk-members
- `dart:core#List#addAll`: kept by call sites and --sdk-members
- `dart:core#List#clear`: kept by call sites and --sdk-members
- `dart:core#List#indexOf`: kept by --sdk-members
- `dart:core#List#insert`: kept by call sites and --sdk-members
- `dart:core#List#removeAt`: kept by call sites and --sdk-members
- `dart:core#List#sublist`: kept by call sites and --sdk-members
- `dart:core#List#tearoff:addAll`: kept by call sites and --sdk-members
- `dart:core#List#tearoff:clear`: kept by call sites and --sdk-members
- `dart:core#List#tearoff:indexOf`: kept by --sdk-members
- `dart:core#List#tearoff:insert`: kept by call sites and --sdk-members
- `dart:core#List#tearoff:removeAt`: kept by call sites and --sdk-members
- `dart:core#List#tearoff:sublist`: kept by call sites and --sdk-members
- `dart:core#Map#containsValue`: kept by call sites and --sdk-members
- `dart:core#Map#get:isNotEmpty`: kept by call sites and --sdk-members
- `dart:core#Map#tearoff:containsValue`: kept by call sites and --sdk-members
- `dart:core#StateError#message`: kept by --sdk-members (thin)
- `dart:core#String#*`: kept by call sites and --sdk-members
- `dart:core#String#codeUnitAt`: kept by --sdk-members
- `dart:core#String#compareTo`: kept by --sdk-members
- `dart:core#String#get:length`: kept by call sites and --sdk-members
- `dart:core#String#indexOf`: kept by --sdk-members
- `dart:core#String#padLeft`: kept by call sites and --sdk-members
- `dart:core#String#substring`: kept by call sites and --sdk-members
- `dart:core#String#tearoff:codeUnitAt`: kept by --sdk-members
- `dart:core#String#tearoff:compareTo`: kept by --sdk-members
- `dart:core#String#tearoff:indexOf`: kept by --sdk-members
- `dart:core#String#tearoff:padLeft`: kept by call sites and --sdk-members
- `dart:core#String#tearoff:substring`: kept by call sites and --sdk-members
- `dart:core#double#%`: kept by --sdk-members (thin)
- `dart:core#double#abs`: kept by --sdk-members (thin)
- `dart:core#double#ceil`: kept by --sdk-members (thin)
- `dart:core#double#floor`: kept by --sdk-members (thin)
- `dart:core#double#round`: kept by --sdk-members (thin)
- `dart:core#double#tearoff:abs`: kept by --sdk-members (thin)
- `dart:core#double#tearoff:ceil`: kept by --sdk-members (thin)
- `dart:core#double#tearoff:floor`: kept by --sdk-members (thin)
- `dart:core#double#tearoff:round`: kept by --sdk-members (thin)
- `dart:core#double#tearoff:truncate`: kept by --sdk-members (thin)
- `dart:core#double#truncate`: kept by --sdk-members (thin)
- `dart:core#double#~/`: kept by call sites and --sdk-members (thin)
- `dart:core#int#abs`: kept by --sdk-members
- `dart:core#int#tearoff:abs`: kept by --sdk-members
- `dart:core#num#%`: kept by --sdk-members
- `dart:core#num#/`: kept by --sdk-members
- `dart:core#num#<=`: kept by --sdk-members
- `dart:core#num#>=`: kept by --sdk-members
- `dart:core#num#abs`: kept by --sdk-members
- `dart:core#num#clamp`: kept by call sites and --sdk-members
- `dart:core#num#compareTo`: kept by --sdk-members
- `dart:core#num#floor`: kept by --sdk-members
- `dart:core#num#remainder`: kept by call sites and --sdk-members
- `dart:core#num#round`: kept by --sdk-members
- `dart:core#num#tearoff:abs`: kept by --sdk-members
- `dart:core#num#tearoff:clamp`: kept by call sites and --sdk-members
- `dart:core#num#tearoff:compareTo`: kept by --sdk-members
- `dart:core#num#tearoff:floor`: kept by --sdk-members
- `dart:core#num#tearoff:remainder`: kept by call sites and --sdk-members
- `dart:core#num#tearoff:round`: kept by --sdk-members
- `dart:core#num#tearoff:toInt`: kept by --sdk-members
- `dart:core#num#tearoff:toStringAsFixed`: kept by call sites and --sdk-members
- `dart:core#num#toInt`: kept by --sdk-members
- `dart:core#num#toStringAsFixed`: kept by call sites and --sdk-members
- `dart:core#num#unary-`: kept by --sdk-members
- `dart:ui#Offset#get:dx`: kept by --sdk-members (thin)
- `dart:ui#Offset#get:dy`: kept by --sdk-members (thin)
- `dart:ui#Size#get:height`: kept by --sdk-members (thin)
- `dart:ui#Size#get:width`: kept by --sdk-members (thin)

## THROWS in the counter release, UNCALLED in the kept release (tear-off keys whose call form is not SAFE) (21)

- `dart:core#Map#tearoff:addAll`: kept by call sites and --sdk-members
- `dynamic#tearoff:ceil`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:clear`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:contains`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:containsValue`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:elementAt`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:every`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:firstWhere`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:fold`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:insert`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:join`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:padLeft`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:reduce`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:remainder`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:removeAt`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:skip`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:sublist`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:substring`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:take`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:toStringAsFixed`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:truncate`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run

## THROWS in the counter release, CRASH in the kept release (43)

- `dynamic#/`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#<=`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#>=`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#containsValue`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:dx`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:dy`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:height`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:inMilliseconds`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:inMinutes`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:inSeconds`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:isActive`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:isBroadcast`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:isNegative`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:microsecondsSinceEpoch`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:month`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:sink`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:tick`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:weekday`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:width`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#get:year`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#insert`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#remainder`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#removeAt`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#sublist`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:abs`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:add`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:codeUnitAt`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:compareTo`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:difference`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:floor`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:indexOf`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:isAfter`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:isBefore`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:map`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:round`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:subtract`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:toInt`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:toIso8601String`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:toList`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:toUtc`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#tearoff:where`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#toStringAsFixed`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#unary-`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run

## THROWS in both (40)

- `dynamic#<<`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#abs`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#any`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#ceil`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#close`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#codeUnitAt`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#compareTo`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#difference`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#elementAt`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#endsWith`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#every`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#firstWhere`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#floor`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#fold`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#indexOf`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#isAfter`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#isBefore`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#join`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#listen`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#map`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#padLeft`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#reduce`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#replaceAll`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#round`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#skip`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#split`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#startsWith`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#substring`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#subtract`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#take`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#toInt`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#toIso8601String`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#toList`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#toLowerCase`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#toSet`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#toUpperCase`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#toUtc`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#trim`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#truncate`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run
- `dynamic#where`: kept by not a target: the retention gate does not cover dynamic keys, do not widen any from this run

## CRASH in the counter release, SAFE in the kept release (7)

- `dart:core#Iterable#any`: kept by not a target (counter verdict was not THROWS)
- `dart:core#Iterable#contains`: kept by not a target (counter verdict was not THROWS)
- `dart:core#Iterable#every`: kept by not a target (counter verdict was not THROWS)
- `dart:core#Iterable#get:isEmpty`: kept by not a target (counter verdict was not THROWS)
- `dart:core#Iterable#get:isNotEmpty`: kept by not a target (counter verdict was not THROWS)
- `dart:core#Iterable#get:last`: kept by not a target (counter verdict was not THROWS)
- `dart:core#List#sort`: kept by not a target (counter verdict was not THROWS)

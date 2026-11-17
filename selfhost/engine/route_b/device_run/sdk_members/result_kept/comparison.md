# Device verdicts vs PR #209

Scope: the kept release (the counter app plus unreachable call sites and a widened `--sdk-members` list, engine cell 2fc41d3f, 1.0.0+64); SAFE means resolved in that release when the member is kept on purpose, not kept by an ordinary app (see RESULT_KEPT.md).

A `#tearoff:` key is SAFE only if its call-form key is SAFE too (the tear-off probe creates the closure and never calls it); otherwise it is UNCALLED.

Device keys 426: {'SAFE': 242, 'CRASH': 90, 'UNCALLED': 44, 'CRASH(host)': 3, 'PARTIAL': 7, 'THROWS': 40}; 60 of the 242 SAFE keys are thin. #209 accepts 75 keys (75 of them on the device matrix). All 1514 probes are keyed.

## Refused by #209, SAFE on the device, not thin (135)

- dart:async#Future#catchError  (4 probes, 4 classes)
- dart:async#Future#tearoff:catchError  (4 probes, 4 classes)
- dart:async#Stream#get:first  (3 probes, 3 classes)
- dart:async#Stream#get:isBroadcast  (3 probes, 3 classes)
- dart:async#Stream#listen  (3 probes, 3 classes)
- dart:async#Stream#map  (3 probes, 3 classes)
- dart:async#Stream#tearoff:map  (3 probes, 3 classes)
- dart:async#Stream#tearoff:toList  (3 probes, 3 classes)
- dart:async#Stream#tearoff:where  (3 probes, 3 classes)
- dart:async#Stream#toList  (3 probes, 3 classes)
- dart:async#Stream#where  (3 probes, 3 classes)
- dart:async#StreamController#add  (2 probes, 2 classes)
- dart:async#StreamController#get:sink  (2 probes, 2 classes)
- dart:async#StreamController#get:stream  (2 probes, 2 classes)
- dart:core#Iterable#any  (3 probes, 3 classes)
- dart:core#Iterable#contains  (9 probes, 8 classes)
- dart:core#Iterable#elementAt  (3 probes, 3 classes)
- dart:core#Iterable#every  (3 probes, 3 classes)
- dart:core#Iterable#firstWhere  (3 probes, 3 classes)
- dart:core#Iterable#fold  (3 probes, 3 classes)
- dart:core#Iterable#get:first  (9 probes, 8 classes)
- dart:core#Iterable#get:isEmpty  (9 probes, 8 classes)
- dart:core#Iterable#get:isNotEmpty  (9 probes, 8 classes)
- dart:core#Iterable#get:iterator  (3 probes, 3 classes)
- dart:core#Iterable#get:last  (9 probes, 8 classes)
- dart:core#Iterable#join  (3 probes, 3 classes)
- dart:core#Iterable#map  (3 probes, 3 classes)
- dart:core#Iterable#reduce  (3 probes, 3 classes)
- dart:core#Iterable#skip  (3 probes, 3 classes)
- dart:core#Iterable#take  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:any  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:contains  (9 probes, 8 classes)
- dart:core#Iterable#tearoff:elementAt  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:every  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:firstWhere  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:fold  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:join  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:map  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:reduce  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:skip  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:take  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:toList  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:toSet  (3 probes, 3 classes)
- dart:core#Iterable#tearoff:where  (3 probes, 3 classes)
- dart:core#Iterable#toList  (3 probes, 3 classes)
- dart:core#Iterable#toSet  (3 probes, 3 classes)
- dart:core#Iterable#where  (3 probes, 3 classes)
- dart:core#Iterator#get:current  (3 probes, 3 classes)
- dart:core#Iterator#moveNext  (3 probes, 3 classes)
- dart:core#List#[]  (6 probes, 6 classes)
- dart:core#List#[]=  (6 probes, 6 classes)
- dart:core#List#add  (6 probes, 6 classes)
- dart:core#List#addAll  (6 probes, 6 classes)
- dart:core#List#clear  (6 probes, 6 classes)
- dart:core#List#get:length  (6 probes, 6 classes)
- dart:core#List#get:reversed  (6 probes, 6 classes)
- dart:core#List#indexOf  (6 probes, 6 classes)
- dart:core#List#insert  (6 probes, 6 classes)
- dart:core#List#remove  (6 probes, 6 classes)
- dart:core#List#removeAt  (6 probes, 6 classes)
- dart:core#List#sort  (6 probes, 6 classes)
- dart:core#List#sublist  (6 probes, 6 classes)
- dart:core#List#tearoff:addAll  (6 probes, 6 classes)
- dart:core#List#tearoff:clear  (6 probes, 6 classes)
- dart:core#List#tearoff:indexOf  (6 probes, 6 classes)
- dart:core#List#tearoff:insert  (6 probes, 6 classes)
- dart:core#List#tearoff:remove  (6 probes, 6 classes)
- dart:core#List#tearoff:removeAt  (6 probes, 6 classes)
- dart:core#List#tearoff:sort  (6 probes, 6 classes)
- dart:core#List#tearoff:sublist  (6 probes, 6 classes)
- dart:core#Map#[]  (4 probes, 4 classes)
- dart:core#Map#[]=  (4 probes, 4 classes)
- dart:core#Map#containsValue  (4 probes, 4 classes)
- dart:core#Map#get:entries  (4 probes, 4 classes)
- dart:core#Map#get:isNotEmpty  (4 probes, 4 classes)
- dart:core#Map#get:keys  (4 probes, 4 classes)
- dart:core#Map#get:values  (4 probes, 4 classes)
- dart:core#Map#putIfAbsent  (4 probes, 4 classes)
- dart:core#Map#remove  (4 probes, 4 classes)
- dart:core#Map#tearoff:containsValue  (4 probes, 4 classes)
- dart:core#Map#tearoff:putIfAbsent  (4 probes, 4 classes)
- dart:core#Map#tearoff:remove  (4 probes, 4 classes)
- dart:core#Object#==  (3 probes, 3 classes)
- dart:core#Set#add  (2 probes, 2 classes)
- dart:core#Set#contains  (2 probes, 2 classes)
- dart:core#Set#tearoff:contains  (2 probes, 2 classes)
- dart:core#String#*  (2 probes, 2 classes)
- dart:core#String#==  (2 probes, 2 classes)
- dart:core#String#codeUnitAt  (2 probes, 2 classes)
- dart:core#String#compareTo  (2 probes, 2 classes)
- dart:core#String#get:length  (2 probes, 2 classes)
- dart:core#String#indexOf  (2 probes, 2 classes)
- dart:core#String#padLeft  (2 probes, 2 classes)
- dart:core#String#substring  (2 probes, 2 classes)
- dart:core#String#tearoff:codeUnitAt  (2 probes, 2 classes)
- dart:core#String#tearoff:compareTo  (2 probes, 2 classes)
- dart:core#String#tearoff:indexOf  (2 probes, 2 classes)
- dart:core#String#tearoff:padLeft  (2 probes, 2 classes)
- dart:core#String#tearoff:substring  (2 probes, 2 classes)
- dart:core#int#&  (2 probes, 2 classes)
- dart:core#int#<<  (2 probes, 2 classes)
- dart:core#int#abs  (2 probes, 2 classes)
- dart:core#int#tearoff:abs  (2 probes, 2 classes)
- dart:core#int#unary-  (2 probes, 2 classes)
- dart:core#num#%  (5 probes, 3 classes)
- dart:core#num#*  (5 probes, 3 classes)
- dart:core#num#+  (5 probes, 3 classes)
- dart:core#num#-  (5 probes, 3 classes)
- dart:core#num#/  (5 probes, 3 classes)
- dart:core#num#<  (6 probes, 3 classes)
- dart:core#num#<=  (6 probes, 3 classes)
- dart:core#num#==  (6 probes, 3 classes)
- dart:core#num#>  (6 probes, 3 classes)
- dart:core#num#>=  (6 probes, 3 classes)
- dart:core#num#abs  (3 probes, 3 classes)
- dart:core#num#clamp  (6 probes, 3 classes)
- dart:core#num#compareTo  (6 probes, 3 classes)
- dart:core#num#floor  (3 probes, 3 classes)
- dart:core#num#remainder  (2 probes, 2 classes)
- dart:core#num#round  (3 probes, 3 classes)
- dart:core#num#tearoff:abs  (3 probes, 3 classes)
- dart:core#num#tearoff:clamp  (6 probes, 3 classes)
- dart:core#num#tearoff:compareTo  (6 probes, 3 classes)
- dart:core#num#tearoff:floor  (3 probes, 3 classes)
- dart:core#num#tearoff:remainder  (2 probes, 2 classes)
- dart:core#num#tearoff:round  (3 probes, 3 classes)
- dart:core#num#tearoff:toInt  (4 probes, 3 classes)
- dart:core#num#tearoff:toStringAsFixed  (6 probes, 3 classes)
- dart:core#num#toInt  (4 probes, 3 classes)
- dart:core#num#toStringAsFixed  (6 probes, 3 classes)
- dart:core#num#unary-  (3 probes, 3 classes)
- dart:core#num#~/  (2 probes, 2 classes)
- dynamic#==  (11 probes, 8 classes)
- dynamic#get:hashCode  (3 probes, 3 classes)
- dynamic#toString  (9 probes, 9 classes)

## Refused by #209, SAFE on the device but thin (49)

Fewer than 2 probes or fewer than 2 runtime classes.

- dart:async#Timer#get:isActive  (1 probes, 1 classes)
- dart:async#Timer#get:tick  (1 probes, 1 classes)
- dart:core#DateTime#add  (1 probes, 1 classes)
- dart:core#DateTime#difference  (1 probes, 1 classes)
- dart:core#DateTime#get:microsecondsSinceEpoch  (1 probes, 1 classes)
- dart:core#DateTime#get:month  (1 probes, 1 classes)
- dart:core#DateTime#get:weekday  (1 probes, 1 classes)
- dart:core#DateTime#get:year  (1 probes, 1 classes)
- dart:core#DateTime#isAfter  (1 probes, 1 classes)
- dart:core#DateTime#isBefore  (1 probes, 1 classes)
- dart:core#DateTime#subtract  (1 probes, 1 classes)
- dart:core#DateTime#tearoff:add  (1 probes, 1 classes)
- dart:core#DateTime#tearoff:difference  (1 probes, 1 classes)
- dart:core#DateTime#tearoff:isAfter  (1 probes, 1 classes)
- dart:core#DateTime#tearoff:isBefore  (1 probes, 1 classes)
- dart:core#DateTime#tearoff:subtract  (1 probes, 1 classes)
- dart:core#DateTime#tearoff:toIso8601String  (1 probes, 1 classes)
- dart:core#DateTime#tearoff:toUtc  (1 probes, 1 classes)
- dart:core#DateTime#toIso8601String  (1 probes, 1 classes)
- dart:core#DateTime#toUtc  (1 probes, 1 classes)
- dart:core#Duration#+  (1 probes, 1 classes)
- dart:core#Duration#>  (1 probes, 1 classes)
- dart:core#Duration#get:inMicroseconds  (1 probes, 1 classes)
- dart:core#Duration#get:inMilliseconds  (1 probes, 1 classes)
- dart:core#Duration#get:inMinutes  (1 probes, 1 classes)
- dart:core#Duration#get:inSeconds  (1 probes, 1 classes)
- dart:core#Duration#get:isNegative  (1 probes, 1 classes)
- dart:core#Error#get:stackTrace  (1 probes, 1 classes)
- dart:core#FormatException#message  (1 probes, 1 classes)
- dart:core#StateError#message  (1 probes, 1 classes)
- dart:core#double#%  (1 probes, 1 classes)
- dart:core#double#+  (1 probes, 1 classes)
- dart:core#double#abs  (1 probes, 1 classes)
- dart:core#double#ceil  (1 probes, 1 classes)
- dart:core#double#floor  (1 probes, 1 classes)
- dart:core#double#round  (1 probes, 1 classes)
- dart:core#double#tearoff:abs  (1 probes, 1 classes)
- dart:core#double#tearoff:ceil  (1 probes, 1 classes)
- dart:core#double#tearoff:floor  (1 probes, 1 classes)
- dart:core#double#tearoff:round  (1 probes, 1 classes)
- dart:core#double#tearoff:truncate  (1 probes, 1 classes)
- dart:core#double#truncate  (1 probes, 1 classes)
- dart:core#double#~/  (1 probes, 1 classes)
- dart:core#num#get:isNaN  (1 probes, 1 classes)
- dart:ui#Offset#get:dx  (1 probes, 1 classes)
- dart:ui#Offset#get:dy  (1 probes, 1 classes)
- dart:ui#Size#get:height  (1 probes, 1 classes)
- dart:ui#Size#get:width  (1 probes, 1 classes)
- dynamic#get:runtimeType  (1 probes, 1 classes)

## Refused by #209, no crash, but some probes never ran (7)

- dynamic#&  (2 probes, 2 classes)
- dynamic#clamp  (6 probes, 3 classes)
- dynamic#moveNext  (3 probes, 3 classes)
- dynamic#putIfAbsent  (4 probes, 4 classes)
- dynamic#tearoff:addAll  (10 probes, 7 classes)
- dynamic#tearoff:clamp  (6 probes, 3 classes)
- dynamic#tearoff:putIfAbsent  (4 probes, 4 classes)

## Tear-off keys whose probes resolved but whose call form is not SAFE (44)

The tear-off probe only creates the closure, so these say nothing about calling it; the verdict is UNCALLED and the call form decides.

- dart:core#Map#tearoff:addAll: call form CRASH  (refused by #209)
- dart:core#Set#tearoff:remove: call form CRASH(host)  (accepted by #209)
- dart:core#String#tearoff:endsWith: call form CRASH  (refused by #209)
- dynamic#tearoff:any: call form THROWS  (refused by #209)
- dynamic#tearoff:catchError: call form CRASH  (refused by #209)
- dynamic#tearoff:ceil: call form THROWS  (refused by #209)
- dynamic#tearoff:clear: call form CRASH  (refused by #209)
- dynamic#tearoff:close: call form THROWS  (accepted by #209)
- dynamic#tearoff:contains: call form CRASH  (refused by #209)
- dynamic#tearoff:containsKey: call form CRASH  (accepted by #209)
- dynamic#tearoff:containsValue: call form CRASH  (refused by #209)
- dynamic#tearoff:elementAt: call form THROWS  (refused by #209)
- dynamic#tearoff:endsWith: call form THROWS  (refused by #209)
- dynamic#tearoff:every: call form THROWS  (refused by #209)
- dynamic#tearoff:firstWhere: call form THROWS  (refused by #209)
- dynamic#tearoff:fold: call form THROWS  (refused by #209)
- dynamic#tearoff:forEach: call form CRASH  (accepted by #209)
- dynamic#tearoff:insert: call form CRASH  (refused by #209)
- dynamic#tearoff:join: call form THROWS  (refused by #209)
- dynamic#tearoff:listen: call form THROWS  (accepted by #209)
- dynamic#tearoff:padLeft: call form THROWS  (refused by #209)
- dynamic#tearoff:reduce: call form THROWS  (refused by #209)
- dynamic#tearoff:remainder: call form CRASH  (refused by #209)
- dynamic#tearoff:remove: call form CRASH  (refused by #209)
- dynamic#tearoff:removeAt: call form CRASH  (refused by #209)
- dynamic#tearoff:removeLast: call form CRASH  (accepted by #209)
- dynamic#tearoff:replaceAll: call form THROWS  (accepted by #209)
- dynamic#tearoff:skip: call form THROWS  (refused by #209)
- dynamic#tearoff:sort: call form CRASH  (refused by #209)
- dynamic#tearoff:split: call form THROWS  (accepted by #209)
- dynamic#tearoff:startsWith: call form THROWS  (accepted by #209)
- dynamic#tearoff:sublist: call form CRASH  (refused by #209)
- dynamic#tearoff:substring: call form THROWS  (refused by #209)
- dynamic#tearoff:take: call form THROWS  (refused by #209)
- dynamic#tearoff:then: call form CRASH  (accepted by #209)
- dynamic#tearoff:timeout: call form CRASH  (accepted by #209)
- dynamic#tearoff:toDouble: call form CRASH  (accepted by #209)
- dynamic#tearoff:toLowerCase: call form THROWS  (accepted by #209)
- dynamic#tearoff:toSet: call form THROWS  (refused by #209)
- dynamic#tearoff:toStringAsFixed: call form CRASH  (refused by #209)
- dynamic#tearoff:toUpperCase: call form THROWS  (accepted by #209)
- dynamic#tearoff:trim: call form THROWS  (accepted by #209)
- dynamic#tearoff:truncate: call form THROWS  (refused by #209)
- dynamic#tearoff:whenComplete: call form CRASH  (accepted by #209)

## Refused by #209, no crash but a NoSuchMethodError on some runtime class (40)

- dynamic#<<
- dynamic#abs
- dynamic#any
- dynamic#ceil
- dynamic#close
- dynamic#codeUnitAt
- dynamic#compareTo
- dynamic#difference
- dynamic#elementAt
- dynamic#endsWith
- dynamic#every
- dynamic#firstWhere
- dynamic#floor
- dynamic#fold
- dynamic#indexOf
- dynamic#isAfter
- dynamic#isBefore
- dynamic#join
- dynamic#listen
- dynamic#map
- dynamic#padLeft
- dynamic#reduce
- dynamic#replaceAll
- dynamic#round
- dynamic#skip
- dynamic#split
- dynamic#startsWith
- dynamic#substring
- dynamic#subtract
- dynamic#take
- dynamic#toInt
- dynamic#toIso8601String
- dynamic#toList
- dynamic#toLowerCase
- dynamic#toSet
- dynamic#toUpperCase
- dynamic#toUtc
- dynamic#trim
- dynamic#truncate
- dynamic#where

## Accepted by #209, crashing on the device or host (1)

- dynamic#tearoff:cancel: CRASH

## Accepted by #209, throwing, uncalled or partly unmeasured on the device (16)

- dart:core#Set#tearoff:remove: UNCALLED
- dynamic#tearoff:close: UNCALLED
- dynamic#tearoff:containsKey: UNCALLED
- dynamic#tearoff:forEach: UNCALLED
- dynamic#tearoff:listen: UNCALLED
- dynamic#tearoff:removeLast: UNCALLED
- dynamic#tearoff:replaceAll: UNCALLED
- dynamic#tearoff:split: UNCALLED
- dynamic#tearoff:startsWith: UNCALLED
- dynamic#tearoff:then: UNCALLED
- dynamic#tearoff:timeout: UNCALLED
- dynamic#tearoff:toDouble: UNCALLED
- dynamic#tearoff:toLowerCase: UNCALLED
- dynamic#tearoff:toUpperCase: UNCALLED
- dynamic#tearoff:trim: UNCALLED
- dynamic#tearoff:whenComplete: UNCALLED

## Accepted by #209, not on the device matrix (0)


## Accepted by #209, SAFE but thin (11)

- dart:async#Timer#cancel  (1 probes, 1 classes)
- dart:async#Timer#tearoff:cancel  (1 probes, 1 classes)
- dart:core#Object#get:runtimeType  (1 probes, 1 classes)
- dart:core#bool#tearoff:toString  (1 probes, 1 classes)
- dart:core#bool#toString  (1 probes, 1 classes)
- dart:core#double#*  (1 probes, 1 classes)
- dart:core#double#-  (1 probes, 1 classes)
- dart:core#double#/  (1 probes, 1 classes)
- dart:core#double#tearoff:toString  (1 probes, 1 classes)
- dart:core#double#toString  (1 probes, 1 classes)
- dart:core#double#unary-  (1 probes, 1 classes)

## Crashing keys

- dart:async#StreamSubscription#cancel: CRASH  (refused by #209)
- dart:async#StreamSubscription#tearoff:cancel: CRASH  (refused by #209)
- dart:core#Map#addAll: CRASH  (refused by #209)
- dart:core#Set#remove: CRASH(host)  (refused by #209)
- dart:core#String#endsWith: CRASH  (refused by #209)
- dart:core#String#get:isNotEmpty: CRASH(host)  (refused by #209)
- dart:core#int#get:isEven: CRASH(host)  (refused by #209)

## Crashing dynamic selectors

%, *, +, -, /, <, <=, >, >=, [], []=, add, addAll, cancel, catchError, clear, contains, containsKey, containsValue, forEach, get:current, get:dx, get:dy, get:entries, get:first, get:height, get:inMicroseconds, get:inMilliseconds, get:inMinutes, get:inSeconds, get:isActive, get:isBroadcast, get:isClosed, get:isEmpty, get:isEven, get:isNaN, get:isNegative, get:isNotEmpty, get:iterator, get:keys, get:last, get:length, get:microsecondsSinceEpoch, get:month, get:reversed, get:sink, get:stackTrace, get:stream, get:tick, get:values, get:weekday, get:width, get:year, insert, message, remainder, remove, removeAt, removeLast, sort, sublist, tearoff:abs, tearoff:add, tearoff:cancel, tearoff:codeUnitAt, tearoff:compareTo, tearoff:difference, tearoff:floor, tearoff:indexOf, tearoff:isAfter, tearoff:isBefore, tearoff:map, tearoff:round, tearoff:subtract, tearoff:toInt, tearoff:toIso8601String, tearoff:toList, tearoff:toUtc, tearoff:where, then, timeout, toDouble, toStringAsFixed, unary-, whenComplete, ~/

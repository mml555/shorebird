# Device verdicts vs PR #209

Scope: one bare `flutter create` app release at engine cell 2fc41d3f; SAFE means resolved in that release (see RESULT.md).

A `#tearoff:` key is SAFE only if its call-form key is SAFE too (the tear-off probe creates the closure and never calls it); otherwise it is UNCALLED.

Device keys 426: {'SAFE': 112, 'THROWS': 224, 'UNCALLED': 24, 'CRASH': 55, 'CRASH(host)': 4, 'PARTIAL': 7}; 18 of the 112 SAFE keys are thin. #209 accepts 75 keys (75 of them on the device matrix). All 1514 probes are keyed.

## Refused by #209, SAFE on the device, not thin (48)

- dart:async#Future#catchError  (4 probes, 4 classes)
- dart:async#Future#tearoff:catchError  (4 probes, 4 classes)
- dart:async#StreamController#add  (2 probes, 2 classes)
- dart:async#StreamController#get:stream  (2 probes, 2 classes)
- dart:core#Iterable#get:first  (9 probes, 8 classes)
- dart:core#Iterable#get:iterator  (3 probes, 3 classes)
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
- dart:core#List#get:length  (6 probes, 6 classes)
- dart:core#List#get:reversed  (6 probes, 6 classes)
- dart:core#List#remove  (6 probes, 6 classes)
- dart:core#List#tearoff:remove  (6 probes, 6 classes)
- dart:core#Map#[]  (4 probes, 4 classes)
- dart:core#Map#[]=  (4 probes, 4 classes)
- dart:core#Map#get:entries  (4 probes, 4 classes)
- dart:core#Map#get:keys  (4 probes, 4 classes)
- dart:core#Map#get:values  (4 probes, 4 classes)
- dart:core#Map#putIfAbsent  (4 probes, 4 classes)
- dart:core#Map#remove  (4 probes, 4 classes)
- dart:core#Map#tearoff:putIfAbsent  (4 probes, 4 classes)
- dart:core#Map#tearoff:remove  (4 probes, 4 classes)
- dart:core#Object#==  (3 probes, 3 classes)
- dart:core#Set#add  (2 probes, 2 classes)
- dart:core#Set#contains  (2 probes, 2 classes)
- dart:core#Set#tearoff:contains  (2 probes, 2 classes)
- dart:core#String#==  (2 probes, 2 classes)
- dart:core#int#&  (2 probes, 2 classes)
- dart:core#int#<<  (2 probes, 2 classes)
- dart:core#int#unary-  (2 probes, 2 classes)
- dart:core#num#*  (5 probes, 3 classes)
- dart:core#num#+  (5 probes, 3 classes)
- dart:core#num#-  (5 probes, 3 classes)
- dart:core#num#<  (6 probes, 3 classes)
- dart:core#num#==  (6 probes, 3 classes)
- dart:core#num#>  (6 probes, 3 classes)
- dart:core#num#~/  (2 probes, 2 classes)
- dynamic#==  (11 probes, 8 classes)
- dynamic#get:hashCode  (3 probes, 3 classes)
- dynamic#toString  (9 probes, 9 classes)

## Refused by #209, SAFE on the device but thin (7)

Fewer than 2 probes or fewer than 2 runtime classes.

- dart:core#Duration#+  (1 probes, 1 classes)
- dart:core#Duration#get:inMicroseconds  (1 probes, 1 classes)
- dart:core#Error#get:stackTrace  (1 probes, 1 classes)
- dart:core#FormatException#message  (1 probes, 1 classes)
- dart:core#double#+  (1 probes, 1 classes)
- dart:core#num#get:isNaN  (1 probes, 1 classes)
- dynamic#get:runtimeType  (1 probes, 1 classes)

## Refused by #209, no crash, but some probes never ran (7)

- dynamic#&  (2 probes, 2 classes)
- dynamic#clamp  (6 probes, 3 classes)
- dynamic#moveNext  (3 probes, 3 classes)
- dynamic#putIfAbsent  (4 probes, 4 classes)
- dynamic#tearoff:addAll  (10 probes, 7 classes)
- dynamic#tearoff:clamp  (6 probes, 3 classes)
- dynamic#tearoff:putIfAbsent  (4 probes, 4 classes)

## Tear-off keys whose probes resolved but whose call form is not SAFE (24)

The tear-off probe only creates the closure, so these say nothing about calling it; the verdict is UNCALLED and the call form decides.

- dart:async#Stream#tearoff:listen: call form THROWS  (accepted by #209)
- dart:core#Iterable#tearoff:any: call form CRASH  (refused by #209)
- dart:core#List#tearoff:sort: call form CRASH  (refused by #209)
- dart:core#Set#tearoff:remove: call form CRASH(host)  (accepted by #209)
- dart:core#String#tearoff:endsWith: call form CRASH  (refused by #209)
- dynamic#tearoff:catchError: call form CRASH  (refused by #209)
- dynamic#tearoff:close: call form THROWS  (accepted by #209)
- dynamic#tearoff:containsKey: call form CRASH  (accepted by #209)
- dynamic#tearoff:endsWith: call form THROWS  (refused by #209)
- dynamic#tearoff:forEach: call form CRASH  (accepted by #209)
- dynamic#tearoff:listen: call form THROWS  (accepted by #209)
- dynamic#tearoff:remove: call form CRASH  (refused by #209)
- dynamic#tearoff:removeLast: call form CRASH  (accepted by #209)
- dynamic#tearoff:replaceAll: call form THROWS  (accepted by #209)
- dynamic#tearoff:sort: call form CRASH  (refused by #209)
- dynamic#tearoff:split: call form THROWS  (accepted by #209)
- dynamic#tearoff:startsWith: call form THROWS  (accepted by #209)
- dynamic#tearoff:then: call form CRASH  (accepted by #209)
- dynamic#tearoff:timeout: call form CRASH  (accepted by #209)
- dynamic#tearoff:toDouble: call form CRASH  (accepted by #209)
- dynamic#tearoff:toLowerCase: call form THROWS  (accepted by #209)
- dynamic#tearoff:toUpperCase: call form THROWS  (accepted by #209)
- dynamic#tearoff:trim: call form THROWS  (accepted by #209)
- dynamic#tearoff:whenComplete: call form CRASH  (accepted by #209)

## Refused by #209, no crash but a NoSuchMethodError on some runtime class (224)

- dart:async#Stream#get:first
- dart:async#Stream#get:isBroadcast
- dart:async#Stream#listen
- dart:async#Stream#map
- dart:async#Stream#tearoff:map
- dart:async#Stream#tearoff:toList
- dart:async#Stream#tearoff:where
- dart:async#Stream#toList
- dart:async#Stream#where
- dart:async#StreamController#get:sink
- dart:async#Timer#get:isActive
- dart:async#Timer#get:tick
- dart:core#DateTime#add
- dart:core#DateTime#difference
- dart:core#DateTime#get:microsecondsSinceEpoch
- dart:core#DateTime#get:month
- dart:core#DateTime#get:weekday
- dart:core#DateTime#get:year
- dart:core#DateTime#isAfter
- dart:core#DateTime#isBefore
- dart:core#DateTime#subtract
- dart:core#DateTime#tearoff:add
- dart:core#DateTime#tearoff:difference
- dart:core#DateTime#tearoff:isAfter
- dart:core#DateTime#tearoff:isBefore
- dart:core#DateTime#tearoff:subtract
- dart:core#DateTime#tearoff:toIso8601String
- dart:core#DateTime#tearoff:toUtc
- dart:core#DateTime#toIso8601String
- dart:core#DateTime#toUtc
- dart:core#Duration#>
- dart:core#Duration#get:inMilliseconds
- dart:core#Duration#get:inMinutes
- dart:core#Duration#get:inSeconds
- dart:core#Duration#get:isNegative
- dart:core#Iterable#elementAt
- dart:core#Iterable#firstWhere
- dart:core#Iterable#fold
- dart:core#Iterable#join
- dart:core#Iterable#map
- dart:core#Iterable#reduce
- dart:core#Iterable#skip
- dart:core#Iterable#take
- dart:core#Iterable#tearoff:contains
- dart:core#Iterable#tearoff:elementAt
- dart:core#Iterable#tearoff:every
- dart:core#Iterable#tearoff:firstWhere
- dart:core#Iterable#tearoff:fold
- dart:core#Iterable#tearoff:join
- dart:core#Iterable#tearoff:map
- dart:core#Iterable#tearoff:reduce
- dart:core#Iterable#tearoff:skip
- dart:core#Iterable#tearoff:take
- dart:core#List#addAll
- dart:core#List#clear
- dart:core#List#indexOf
- dart:core#List#insert
- dart:core#List#removeAt
- dart:core#List#sublist
- dart:core#List#tearoff:addAll
- dart:core#List#tearoff:clear
- dart:core#List#tearoff:indexOf
- dart:core#List#tearoff:insert
- dart:core#List#tearoff:removeAt
- dart:core#List#tearoff:sublist
- dart:core#Map#containsValue
- dart:core#Map#get:isNotEmpty
- dart:core#Map#tearoff:addAll
- dart:core#Map#tearoff:containsValue
- dart:core#StateError#message
- dart:core#String#*
- dart:core#String#codeUnitAt
- dart:core#String#compareTo
- dart:core#String#get:length
- dart:core#String#indexOf
- dart:core#String#padLeft
- dart:core#String#substring
- dart:core#String#tearoff:codeUnitAt
- dart:core#String#tearoff:compareTo
- dart:core#String#tearoff:indexOf
- dart:core#String#tearoff:padLeft
- dart:core#String#tearoff:substring
- dart:core#double#%
- dart:core#double#abs
- dart:core#double#ceil
- dart:core#double#floor
- dart:core#double#round
- dart:core#double#tearoff:abs
- dart:core#double#tearoff:ceil
- dart:core#double#tearoff:floor
- dart:core#double#tearoff:round
- dart:core#double#tearoff:truncate
- dart:core#double#truncate
- dart:core#double#~/
- dart:core#int#abs
- dart:core#int#tearoff:abs
- dart:core#num#%
- dart:core#num#/
- dart:core#num#<=
- dart:core#num#>=
- dart:core#num#abs
- dart:core#num#clamp
- dart:core#num#compareTo
- dart:core#num#floor
- dart:core#num#remainder
- dart:core#num#round
- dart:core#num#tearoff:abs
- dart:core#num#tearoff:clamp
- dart:core#num#tearoff:compareTo
- dart:core#num#tearoff:floor
- dart:core#num#tearoff:remainder
- dart:core#num#tearoff:round
- dart:core#num#tearoff:toInt
- dart:core#num#tearoff:toStringAsFixed
- dart:core#num#toInt
- dart:core#num#toStringAsFixed
- dart:core#num#unary-
- dart:ui#Offset#get:dx
- dart:ui#Offset#get:dy
- dart:ui#Size#get:height
- dart:ui#Size#get:width
- dynamic#/
- dynamic#<<
- dynamic#<=
- dynamic#>=
- dynamic#abs
- dynamic#any
- dynamic#ceil
- dynamic#close
- dynamic#codeUnitAt
- dynamic#compareTo
- dynamic#containsValue
- dynamic#difference
- dynamic#elementAt
- dynamic#endsWith
- dynamic#every
- dynamic#firstWhere
- dynamic#floor
- dynamic#fold
- dynamic#get:dx
- dynamic#get:dy
- dynamic#get:height
- dynamic#get:inMilliseconds
- dynamic#get:inMinutes
- dynamic#get:inSeconds
- dynamic#get:isActive
- dynamic#get:isBroadcast
- dynamic#get:isNegative
- dynamic#get:microsecondsSinceEpoch
- dynamic#get:month
- dynamic#get:sink
- dynamic#get:tick
- dynamic#get:weekday
- dynamic#get:width
- dynamic#get:year
- dynamic#indexOf
- dynamic#insert
- dynamic#isAfter
- dynamic#isBefore
- dynamic#join
- dynamic#listen
- dynamic#map
- dynamic#padLeft
- dynamic#reduce
- dynamic#remainder
- dynamic#removeAt
- dynamic#replaceAll
- dynamic#round
- dynamic#skip
- dynamic#split
- dynamic#startsWith
- dynamic#sublist
- dynamic#substring
- dynamic#subtract
- dynamic#take
- dynamic#tearoff:abs
- dynamic#tearoff:add
- dynamic#tearoff:ceil
- dynamic#tearoff:clear
- dynamic#tearoff:codeUnitAt
- dynamic#tearoff:compareTo
- dynamic#tearoff:contains
- dynamic#tearoff:containsValue
- dynamic#tearoff:difference
- dynamic#tearoff:elementAt
- dynamic#tearoff:every
- dynamic#tearoff:firstWhere
- dynamic#tearoff:floor
- dynamic#tearoff:fold
- dynamic#tearoff:indexOf
- dynamic#tearoff:insert
- dynamic#tearoff:isAfter
- dynamic#tearoff:isBefore
- dynamic#tearoff:join
- dynamic#tearoff:map
- dynamic#tearoff:padLeft
- dynamic#tearoff:reduce
- dynamic#tearoff:remainder
- dynamic#tearoff:removeAt
- dynamic#tearoff:round
- dynamic#tearoff:skip
- dynamic#tearoff:sublist
- dynamic#tearoff:substring
- dynamic#tearoff:subtract
- dynamic#tearoff:take
- dynamic#tearoff:toInt
- dynamic#tearoff:toIso8601String
- dynamic#tearoff:toList
- dynamic#tearoff:toStringAsFixed
- dynamic#tearoff:toUtc
- dynamic#tearoff:truncate
- dynamic#tearoff:where
- dynamic#toInt
- dynamic#toIso8601String
- dynamic#toList
- dynamic#toLowerCase
- dynamic#toSet
- dynamic#toStringAsFixed
- dynamic#toUpperCase
- dynamic#toUtc
- dynamic#trim
- dynamic#truncate
- dynamic#unary-
- dynamic#where

## Accepted by #209, crashing on the device or host (1)

- dynamic#tearoff:cancel: CRASH

## Accepted by #209, throwing, uncalled or partly unmeasured on the device (17)

- dart:async#Stream#tearoff:listen: UNCALLED
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
- dart:core#Iterable#any: CRASH  (refused by #209)
- dart:core#Iterable#contains: CRASH  (refused by #209)
- dart:core#Iterable#every: CRASH  (refused by #209)
- dart:core#Iterable#get:isEmpty: CRASH  (refused by #209)
- dart:core#Iterable#get:isNotEmpty: CRASH  (refused by #209)
- dart:core#Iterable#get:last: CRASH  (refused by #209)
- dart:core#List#sort: CRASH  (refused by #209)
- dart:core#Map#addAll: CRASH  (refused by #209)
- dart:core#Set#remove: CRASH(host)  (refused by #209)
- dart:core#String#endsWith: CRASH  (refused by #209)
- dart:core#String#get:isNotEmpty: CRASH(host)  (refused by #209)
- dart:core#int#get:isEven: CRASH(host)  (refused by #209)

## Crashing dynamic selectors

%, *, +, -, <, >, [], []=, add, addAll(host), cancel, catchError, clear, contains, containsKey, forEach, get:current, get:entries, get:first, get:inMicroseconds, get:isClosed, get:isEmpty, get:isEven, get:isNaN, get:isNotEmpty, get:iterator, get:keys, get:last, get:length, get:reversed, get:stackTrace, get:stream, get:values, message, remove, removeLast, sort, tearoff:any, tearoff:cancel, tearoff:toSet, then, timeout, toDouble, whenComplete, ~/

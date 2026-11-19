// cspell:words vm_shared
/// How the per-release SDK-member check decides a `dart:` BASE class (one
/// that others extend, implement or mix in) with compiled code that the
/// release is not seen to allocate: no `[Stub] Allocate` stub, no const
/// instance. Keys are `library#Class`, private-library suffix dropped.
///
/// Compiled code allocates an ordinary class only through that class's own
/// allocation stub (`runtime/vm/compiler/backend/il.cc:6423`,
/// `AllocateObjectInstr` calls `StubCode::GetAllocationStubForClass(cls_)`),
/// so an ordinary class with no stub has no instance in the release. The
/// classes with a fixed class id are different: the VM, the runtime and
/// inline IL allocate them with no per-class stub (`_List`, `_GrowableList`,
/// `_ImmutableList`, `_Closure`, `_Record`, `_Smi`, `_Mint`, `_Double`,
/// `_OneByteString`, typed data and its views). So such a base class counts
/// as concrete when it is in [routeBVmFixedIdClasses] and not in
/// [routeBSdkAbstractBases], and is skipped otherwise.
///
/// Both lists come from engine d0714887 (release 1.0.0+70; Dart in
/// `engine/src/flutter/third_party/dart`).
/// `test/fixtures/route_b_sdk_kept/stubless_sdk_bases.tsv` pins the 198 such
/// classes in that release's profile, and its test fails on one that is in
/// neither list and not reviewed, so an SDK bump gets a human look.
library;

/// The `dart:` classes the VM gives a fixed class id
/// (`runtime/vm/class_id.h`), by the names `Object::Init` registers them
/// under (`runtime/vm/object.cc`, `RegisterClass`/`RegisterPrivateClass`;
/// names from `runtime/vm/symbol_list.h`). Some are abstract (`int`, `num`);
/// [routeBSdkAbstractBases] takes precedence.
const routeBVmFixedIdClasses = {
  'dart:_internal#FinalizerEntry',
  'dart:async#FutureOr',
  'dart:async#_SuspendState',
  'dart:_compact_hash#_ConstMap',
  'dart:_compact_hash#_ConstSet',
  'dart:_compact_hash#_LinkedHashBase',
  'dart:_compact_hash#_Map',
  'dart:_compact_hash#_Set',
  'dart:core#Function',
  'dart:core#Null',
  'dart:core#Record',
  'dart:core#Type',
  'dart:core#_Closure',
  'dart:core#_Double',
  'dart:core#_FinalizerImpl',
  'dart:core#_FunctionType',
  'dart:core#_GrowableList',
  'dart:core#_ImmutableList',
  'dart:core#_IntegerImplementation',
  'dart:core#_LibraryPrefix',
  'dart:core#_List',
  'dart:core#_Mint',
  'dart:core#_OneByteString',
  'dart:core#_Record',
  'dart:core#_RecordType',
  'dart:core#_RegExp',
  'dart:core#_Smi',
  'dart:core#_StackTrace',
  'dart:core#_TwoByteString',
  'dart:core#_Type',
  'dart:core#_TypeParameter',
  'dart:core#_WeakProperty',
  'dart:core#_WeakReference',
  'dart:core#bool',
  'dart:core#double',
  'dart:core#int',
  'dart:core#num',
  'dart:developer#_UserTag',
  'dart:ffi#Bool',
  'dart:ffi#Double',
  'dart:ffi#DynamicLibrary',
  'dart:ffi#Float',
  'dart:ffi#Handle',
  'dart:ffi#Int16',
  'dart:ffi#Int32',
  'dart:ffi#Int64',
  'dart:ffi#Int8',
  'dart:ffi#NativeFunction',
  'dart:ffi#NativeType',
  'dart:ffi#Pointer',
  'dart:ffi#Uint16',
  'dart:ffi#Uint32',
  'dart:ffi#Uint64',
  'dart:ffi#Uint8',
  'dart:ffi#Void',
  'dart:ffi#_NativeFinalizer',
  'dart:isolate#_Capability',
  'dart:isolate#_RawReceivePort',
  'dart:isolate#_SendPort',
  'dart:isolate#_TransferableTypedDataImpl',
  'dart:mirrors#_MirrorReference',
  'dart:typed_data#Float32x4',
  'dart:typed_data#Float64x2',
  'dart:typed_data#Int32x4',
  'dart:typed_data#_ByteBuffer',
  'dart:typed_data#_ByteDataView',
  'dart:typed_data#_ExternalFloat32Array',
  'dart:typed_data#_ExternalFloat32x4Array',
  'dart:typed_data#_ExternalFloat64Array',
  'dart:typed_data#_ExternalFloat64x2Array',
  'dart:typed_data#_ExternalInt16Array',
  'dart:typed_data#_ExternalInt32Array',
  'dart:typed_data#_ExternalInt32x4Array',
  'dart:typed_data#_ExternalInt64Array',
  'dart:typed_data#_ExternalInt8Array',
  'dart:typed_data#_ExternalUint16Array',
  'dart:typed_data#_ExternalUint32Array',
  'dart:typed_data#_ExternalUint64Array',
  'dart:typed_data#_ExternalUint8Array',
  'dart:typed_data#_ExternalUint8ClampedArray',
  'dart:typed_data#_Float32ArrayView',
  'dart:typed_data#_Float32List',
  'dart:typed_data#_Float32x4',
  'dart:typed_data#_Float32x4ArrayView',
  'dart:typed_data#_Float32x4List',
  'dart:typed_data#_Float64ArrayView',
  'dart:typed_data#_Float64List',
  'dart:typed_data#_Float64x2',
  'dart:typed_data#_Float64x2ArrayView',
  'dart:typed_data#_Float64x2List',
  'dart:typed_data#_Int16ArrayView',
  'dart:typed_data#_Int16List',
  'dart:typed_data#_Int32ArrayView',
  'dart:typed_data#_Int32List',
  'dart:typed_data#_Int32x4',
  'dart:typed_data#_Int32x4ArrayView',
  'dart:typed_data#_Int32x4List',
  'dart:typed_data#_Int64ArrayView',
  'dart:typed_data#_Int64List',
  'dart:typed_data#_Int8ArrayView',
  'dart:typed_data#_Int8List',
  'dart:typed_data#_Uint16ArrayView',
  'dart:typed_data#_Uint16List',
  'dart:typed_data#_Uint32ArrayView',
  'dart:typed_data#_Uint32List',
  'dart:typed_data#_Uint64ArrayView',
  'dart:typed_data#_Uint64List',
  'dart:typed_data#_Uint8ArrayView',
  'dart:typed_data#_Uint8ClampedArrayView',
  'dart:typed_data#_Uint8ClampedList',
  'dart:typed_data#_Uint8List',
  'dart:typed_data#_UnmodifiableByteDataView',
  'dart:typed_data#_UnmodifiableFloat32ArrayView',
  'dart:typed_data#_UnmodifiableFloat32x4ArrayView',
  'dart:typed_data#_UnmodifiableFloat64ArrayView',
  'dart:typed_data#_UnmodifiableFloat64x2ArrayView',
  'dart:typed_data#_UnmodifiableInt16ArrayView',
  'dart:typed_data#_UnmodifiableInt32ArrayView',
  'dart:typed_data#_UnmodifiableInt32x4ArrayView',
  'dart:typed_data#_UnmodifiableInt64ArrayView',
  'dart:typed_data#_UnmodifiableInt8ArrayView',
  'dart:typed_data#_UnmodifiableUint16ArrayView',
  'dart:typed_data#_UnmodifiableUint32ArrayView',
  'dart:typed_data#_UnmodifiableUint64ArrayView',
  'dart:typed_data#_UnmodifiableUint8ArrayView',
  'dart:typed_data#_UnmodifiableUint8ClampedArrayView',
};

/// `dart:` classes that are ABSTRACT although they have compiled code and
/// subclasses. Each is abstract in its declaration (path and modifiers above
/// it; `@patch` files keep the original's modifiers). An anonymous mixin
/// application (a name with `&`) is not listed: the CFE always makes one
/// abstract (`pkg/front_end/lib/src/source/source_class_builder.dart`,
/// `modifiers: Modifiers.Abstract`). A class that could not be shown abstract
/// is not listed.
const routeBSdkAbstractBases = {
  // sdk/lib/internal/list.dart: abstract class
  'dart:_internal#FixedLengthListBase',
  // sdk/lib/internal/iterable.dart: abstract class
  'dart:_internal#ListIterable',
  // sdk/lib/internal/list.dart: abstract class
  'dart:_internal#UnmodifiableListBase',
  // sdk/lib/internal/cast.dart: abstract class
  'dart:_internal#_CastIterableBase',
  // sdk/lib/internal/cast.dart: abstract class
  'dart:_internal#_CastListBase',
  // sdk/lib/async/future.dart: abstract interface class
  'dart:async#Future',
  // sdk/lib/async/future_impl.dart: abstract class
  'dart:async#_Completer',
  // sdk/lib/async/stream_impl.dart: abstract class
  'dart:async#_DelayedEvent',
  // sdk/lib/async/stream_controller.dart: abstract class
  'dart:async#_StreamController',
  // sdk/lib/async/stream_impl.dart: abstract class
  'dart:async#_StreamImpl',
  // sdk/lib/async/zone.dart: abstract base class
  'dart:async#_Zone',
  // sdk/lib/collection/list.dart: abstract mixin class
  'dart:collection#ListBase',
  // sdk/lib/collection/maps.dart: abstract mixin class
  'dart:collection#MapBase',
  // sdk/lib/collection/set.dart: abstract mixin class
  'dart:collection#SetBase',
  // sdk/lib/_internal/vm_shared/lib/collection_patch.dart: abstract class
  'dart:collection#_HashMapIterable',
  // sdk/lib/_internal/vm_shared/lib/collection_patch.dart: abstract class
  'dart:collection#_HashMapIterator',
  // sdk/lib/collection/set.dart: abstract class
  'dart:collection#_SetBase',
  // sdk/lib/convert/codec.dart: abstract mixin class
  'dart:convert#Codec',
  // sdk/lib/convert/json.dart: abstract class
  'dart:convert#_JsonStringifier',
  // sdk/lib/core/iterable.dart: abstract mixin class
  'dart:core#Iterable',
  // sdk/lib/core/map.dart: abstract interface class
  'dart:core#Map',
  // sdk/lib/_internal/vm/lib/type_patch.dart: abstract class
  'dart:core#_AbstractType',
  // sdk/lib/_internal/vm/lib/array.dart: abstract class
  'dart:core#_Array',
  // sdk/lib/core/enum.dart: abstract class
  'dart:core#_Enum',
  // sdk/lib/_internal/vm/lib/integers.dart: abstract final class
  'dart:core#_IntegerImplementation',
  // sdk/lib/_internal/vm/lib/string_patch.dart: abstract final class
  'dart:core#_StringBase',
  // sdk/lib/io/directory.dart: abstract interface class
  'dart:io#Directory',
  // sdk/lib/io/file.dart: abstract interface class
  'dart:io#File',
  // sdk/lib/io/link.dart: abstract interface class
  'dart:io#Link',
  // sdk/lib/io/secure_socket.dart: abstract interface class
  'dart:io#X509Certificate',
  // sdk/lib/io/namespace_impl.dart: abstract class
  'dart:io#_Namespace',
  // sdk/lib/typed_data/typed_data.dart: abstract final class
  'dart:typed_data#ByteData',
  // sdk/lib/_internal/vm/lib/typed_data_patch.dart: abstract final class
  'dart:typed_data#_TypedList',
  // sdk/lib/_internal/vm/lib/typed_data_patch.dart: abstract final class
  'dart:typed_data#_TypedListBase',
  // sdk/lib/_internal/vm/lib/typed_data_patch.dart: abstract final class
  'dart:typed_data#_TypedListView',
  // lib/ui/geometry.dart: abstract class
  'dart:ui#OffsetBase',
  // lib/ui/geometry.dart: abstract class
  'dart:ui#_RRectLike',
};

# New edits (cell a6a48cf6): s1b, s1, i1, i2b must publish and show new values (patches 6-9, after steps2's
# rollback of 5). e1b (an extension getter using `this`) is refused: a replacement cannot pass the receiver. Then refusals measured in the dry run: i2 (num./), e1 (String.*),
# p16 (Iterable.join), p17 (Iterable.map/toList), t1 (class type parameter). Any of those publishing is reported.
. "$(dirname "$0")/lib.sh"
for v in s1b_static_unqualified_nested:s1b s1_static_unqualified:s1 i1_int_ops:i1 i2b_double_mul:i2b; do
  name=${v#*:}; var=${v%%:*}
  patch $var $name || echo "PATCH $name FAILED"
  launch ${name}_download
  launch ${name}_boot
  launch ${name}_boot2
done
for v in i2_double_op:i2 e1_extension_static:e1 e1b_extension_static_interp:e1b p16_sdk_list_add:p16 p17_sdk_chain:p17 t1_class_type_param_refusal:t1; do
  name=${v#*:}; var=${v%%:*}
  patch $var refuse_$name && { echo "$name PUBLISHED"; launch ${name}_download; launch ${name}_boot; launch ${name}_boot2; }
done
echo "--- patches on server:"; cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -15
echo STEPS3_DONE

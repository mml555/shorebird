# Android steps: release launches, then each variant (publish -> 3 launches; refused -> recorded), then two rollbacks.
. "$(dirname "$0")/lib.sh"
launch boot_release shot
launch boot_release2
try_patch combo combo_p15
try_patch p03_setstate_closure+p16b_sdk_list_add_length+p29_const_only+p07_async_loop trio
try_patch p15_dep_body p15
try_patch m2_new_private_method_calls_and_writes m2
try_patch p20_const const
try_patch p30_field_initializer field
try_patch r1_new_public_method_tojson r1
try_patch p17_sdk_chain p17
try_patch t1_class_type_param_refusal t1
echo "--- patches on server:"; cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -20; cd $R
cat $NUMS
last=$(tail -1 $NUMS); rollback "${last#* }" rollback1
launch rb1_learn; launch rb1_boot; launch rb1_boot2
last2=$(tail -2 $NUMS | head -1); rollback "${last2#* }" rollback2
launch rb2_learn; launch rb2_boot; launch rb2_boot2
echo STEPS_DONE

# Signed iPhone steps (cell f2458551, kept check on). Release carries key A's public key. Signed (A) patches must publish and apply;
# an unsigned patch, a key-B patch and an A-public/B-private mismatch must be refused (by the CLI, or else by the device).
. "$(dirname "$0")/lib.sh"
launch boot_release
launch boot_release2
patch p03_setstate_closure+p16b_sdk_list_add_length+p29_const_only+p07_async_loop trio || echo "TRIO PATCH FAILED"
launch trio_download; launch trio_boot shot; launch trio_boot2
neg_patch combo_nop15 neg_unsigned ""
neg_patch combo_nop15 neg_keyb "--public-key-path=$R/keys/b_public.pem --private-key-path=$R/keys/b_private.pem"
neg_patch combo_nop15 neg_mismatch "--public-key-path=$R/keys/a_public.pem --private-key-path=$R/keys/b_private.pem"
patch combo_nop15 combo || echo "COMBO PATCH FAILED"
launch combo_download; launch combo_boot shot; launch combo_boot2
cat $NUMS
rollback "$(num combo)" rollback
launch rb_learn; launch rb_boot; launch rb_boot2
echo STEPS_DONE

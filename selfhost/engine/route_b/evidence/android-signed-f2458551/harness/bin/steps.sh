# cspell:words keyb NUMS
# Signed Android steps. Release carries key A's public key. Signed (A) patches must publish and apply; an unsigned patch, a key-B patch
# and an A-public/B-private mismatch must be refused (by the CLI, or else by the device). Then the same APK with armeabi-v7a only.
. "$(dirname "$0")/lib.sh"
launch boot_release shot
launch boot_release2
try_patch p03_setstate_closure+p16b_sdk_list_add_length+p29_const_only+p07_async_loop trio
neg_patch p15_dep_body neg_unsigned ""
neg_patch p15_dep_body neg_keyb "--public-key-path=$R/keys/b_public.pem --private-key-path=$R/keys/b_private.pem"
neg_patch p15_dep_body neg_mismatch "--public-key-path=$R/keys/a_public.pem --private-key-path=$R/keys/b_private.pem"
try_patch p15_dep_body p15
echo "--- patches on server (arm64 phase):"; cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -20; cd $R
echo "=== armeabi-v7a phase"
abi_reinstall armeabi-v7a
launch arm32_download shot
launch arm32_boot
launch arm32_boot2
try_patch m2_new_private_method_calls_and_writes arm32_m2
cat $NUMS
last=$(tail -1 $NUMS); rollback "${last#* }" rollback1
launch rb1_learn; launch rb1_boot; launch rb1_boot2
echo STEPS_DONE

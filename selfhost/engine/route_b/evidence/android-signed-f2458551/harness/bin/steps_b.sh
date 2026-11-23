# cspell:words keyb NUMS
# Device-side signature check: the key-B patch is refused by the CLI only through the asset diff (the generated shorebird.yaml
# carries B's public key), so force it with --allow-asset-diffs and expect the phone (release embeds A) to reject it. Then an A patch.
. "$(dirname "$0")/lib.sh"
launch b_before
neg_patch p20_const neg_keyb_forced "--public-key-path=$R/keys/b_public.pem --private-key-path=$R/keys/b_private.pem --allow-asset-diffs"
try_patch p20_const p20
cat $NUMS
echo STEPS_B_DONE

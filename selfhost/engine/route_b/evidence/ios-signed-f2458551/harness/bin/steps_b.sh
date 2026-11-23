# Device-side signature check: the key-B patch is refused by the CLI only through the asset diff (the generated (bundled)
# shorebird.yaml carries B's public key), so force it with --allow-asset-diffs and expect the iPhone (release embeds A) to
# reject it. Then the same code signed with A must apply.
. "$(dirname "$0")/lib.sh"
launch b_before
neg_patch combo_nop15 neg_keyb_forced "--public-key-path=$R/keys/b_public.pem --private-key-path=$R/keys/b_private.pem --allow-asset-diffs"
patch combo_nop15 combo2 || echo "COMBO2 PATCH FAILED"
launch combo2_download; launch combo2_boot shot; launch combo2_boot2
cat $NUMS
echo STEPS_B_DONE

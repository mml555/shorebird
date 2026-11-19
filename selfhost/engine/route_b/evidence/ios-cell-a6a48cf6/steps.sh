# Regression (cell a6a48cf6): release launches, combo patch, trio patch, p20/p30 refusals, rollback of patch 2.
. "$(dirname "$0")/lib.sh"
launch boot_release
launch boot_release2
patch combo combo || echo "COMBO PATCH FAILED"
launch combo_download
launch combo_boot shot
launch combo_boot2
patch p03_setstate_closure+p16b_sdk_list_add_length+p29_const_only+p07_async_loop trio || echo "TRIO PATCH FAILED"
launch trio_download
launch trio_boot shot
launch trio_boot2
patch p20_const refuse_const && echo "UNEXPECTED: p20 published"
patch p30_field_initializer refuse_field && echo "UNEXPECTED: p30 published"
cd $APP; $SB patches rollback --release-version $VERSION --patch-number 2 > $R/logs/rollback.log 2>&1
echo "rollback exit=$?"; tail -3 $R/logs/rollback.log
launch rb_learn
launch rb_boot
launch rb_boot2
echo STEPS_DONE

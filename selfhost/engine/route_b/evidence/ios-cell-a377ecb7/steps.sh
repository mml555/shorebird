# Regression (cell a377ecb7, Flutter 3.50, check on): release launches; the combo with p15 (expected refused by #251), the combo
# without p15, trio; p20/p30/p15 refusals; rollback of trio. A refusal that publishes instead is launched and reported.
. "$(dirname "$0")/lib.sh"
expect_refused() { # $1 variant, $2 name
  if patch $1 refuse_$2; then echo "UNEXPECTED: $2 published"; launch ${2}_download; launch ${2}_boot; launch ${2}_boot2; else echo "$2 REFUSED"; fi
}
launch boot_release
launch boot_release2
expect_refused combo combo_p15
patch combo_nop15 combo || echo "COMBO PATCH FAILED"
launch combo_download
launch combo_boot shot
launch combo_boot2
patch p03_setstate_closure+p16b_sdk_list_add_length+p29_const_only+p07_async_loop trio || echo "TRIO PATCH FAILED"
launch trio_download
launch trio_boot shot
launch trio_boot2
expect_refused p20_const const
expect_refused p30_field_initializer field
expect_refused p15_dep_body p15
rollback "$(num trio)" rollback
launch rb_learn
launch rb_boot
launch rb_boot2
echo STEPS_DONE

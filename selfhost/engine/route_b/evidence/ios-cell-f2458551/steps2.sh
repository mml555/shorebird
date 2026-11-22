# Cell 2fc41d3f's edits, check on: h1, m1, m2 must publish; r1, r2 must be refused before upload; then roll back m2.
. "$(dirname "$0")/lib.sh"
for v in h1_new_private_top_level_fn:h1 m1_new_private_method:m1 m2_new_private_method_calls_and_writes:m2; do
  name=${v#*:}; var=${v%%:*}
  patch $var $name || echo "PATCH $name FAILED"
  launch ${name}_download
  launch ${name}_boot
  launch ${name}_boot2
done
patch r1_new_public_method_tojson refuse_r1 && echo "UNEXPECTED: r1 published"
patch r2_new_private_method_name_collision refuse_r2 && echo "UNEXPECTED: r2 published"
echo "--- patches on server:"; cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -15
echo "--- rollback m2"
rollback "$(num m2)" rollback2
launch rb2_learn
launch rb2_boot
launch rb2_boot2
echo STEPS2_DONE

# Cell a6a48cf6, 2026-11-19: i2 and p16 rerun past the Iterable.iterator false positive (#247), verdict only: a patch
# that publishes here is recorded, not launched (steps4.sh was stopped after p20 so nothing it published could boot).
. "$(dirname "$0")/lib.sh"
for v in i2_double_op:i2 p16_sdk_list_add:p16; do
  name=${v#*:}; var=${v%%:*}
  if patch $var unchecked_$name; then echo "$name PUBLISHED (not launched)"; else echo "$name REFUSED"; fi
done
echo "--- patches on server:"; cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -15
echo STEPS4B_DONE

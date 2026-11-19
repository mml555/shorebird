# Cell a6a48cf6, 2026-11-19: p20, i2 and p16 were refused in steps.sh/steps3.sh only for the Iterable.iterator false
# positive (#247), so their own verdict was never reached. Rerun each (patch() retries that refusal alone with
# --allow-unchecked-sdk-calls); any that publishes is launched three times like the others.
. "$(dirname "$0")/lib.sh"
for v in p20_const:p20 i2_double_op:i2 p16_sdk_list_add:p16; do
  name=${v#*:}; var=${v%%:*}
  if patch $var unchecked_$name; then
    echo "$name PUBLISHED"; launch ${name}_download; launch ${name}_boot; launch ${name}_boot2
  fi
done
echo "--- patches on server:"; cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -15
echo STEPS4_DONE

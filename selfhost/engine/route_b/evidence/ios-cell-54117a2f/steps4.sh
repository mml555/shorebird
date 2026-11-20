# Third rollback: the newest published patch; the device must fall back to the one before it.
# cspell:words NUMS
. "$(dirname "$0")/lib.sh"
last=$(tail -1 $NUMS); echo "newest: $last"
rollback "${last#* }" rollback3
launch rb3_learn
launch rb3_boot
launch rb3_boot2
echo STEPS4_DONE

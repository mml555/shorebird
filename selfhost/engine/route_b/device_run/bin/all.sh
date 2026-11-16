#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2164,SC2034
D="$(dirname "$0")"
. "${DEVRUN_ENV:-$D/../env.sh}" || exit 1
bash $D/steps.sh > $R/logs/steps.out 2>&1; echo "steps exit=$?" >> $R/logs/steps.out
bash $D/steps2.sh > $R/logs/steps2.out 2>&1; echo "steps2 exit=$?" >> $R/logs/steps2.out

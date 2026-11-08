# VOID — armed as ACQ, but the acquisition had already happened

Its own `pre_state` showed `next_boot_patch=6` with patches 5 and 6 present, so a
launch here would have been a FIRST ACTIVATION recorded under an acquisition label.
Nothing was observed through this arm. Superseded by `run_007gen_A_first_activation`.

Second time this has happened (see `run_006_ACQ_armed/VOID.md`): a launch slips in
between publishing a patch and arming the acquisition run. The just-in-time arming
procedure does not prevent it, because the acquiring launch can happen before the
operator is at the phone at all.

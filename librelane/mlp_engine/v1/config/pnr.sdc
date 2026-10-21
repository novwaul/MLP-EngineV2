# Implementation-only over-constraint: tighter DRV limits than signoff so
# post-route parasitics and antenna diodes do not push nets past signoff limits.
set _signoff_fanout $::env(MAX_FANOUT_CONSTRAINT)
set _signoff_tran $::env(MAX_TRANSITION_CONSTRAINT)
set _signoff_cap $::env(MAX_CAPACITANCE_CONSTRAINT)
set ::env(MAX_FANOUT_CONSTRAINT) 8
set ::env(MAX_TRANSITION_CONSTRAINT) 0.75
set ::env(MAX_CAPACITANCE_CONSTRAINT) 0.15
source $::env(SCRIPTS_DIR)/base.sdc
set ::env(MAX_FANOUT_CONSTRAINT) $_signoff_fanout
set ::env(MAX_TRANSITION_CONSTRAINT) $_signoff_tran
set ::env(MAX_CAPACITANCE_CONSTRAINT) $_signoff_cap

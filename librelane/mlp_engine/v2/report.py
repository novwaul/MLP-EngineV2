#!/usr/bin/env python3
"""Summarize actual LibreLane output; absent checks are never marked as passed."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('run', type=Path)
args = parser.parse_args()
run = args.run.resolve()
states = sorted(run.glob('[0-9]*-*/state_out.json'))
final_metrics = run / 'final/metrics.json'
# A --to run also exports final/metrics.json. During a resumed run that file
# can still describe synthesis, so use the latest completed step instead.
metrics = json.loads(states[-1].read_text()).get('metrics', {}) if states else {}
keys = ['design__instance__count', 'design__instance__area',
        'design__instance__area__stdcell', 'design__instance__area__macros',
        'timing__setup__ws', 'timing__hold__ws', 'timing__setup__tns',
        'timing__hold__tns', 'timing__setup_vio__count', 'timing__hold_vio__count',
        'timing__unconstrained__count', 'route__drc_errors',
        'design__critical_disconnected_pin__count',
        'design__max_slew_violation__count', 'design__max_cap_violation__count',
        'design__max_fanout_violation__count',
        'design__xor_difference__count',
        'magic__drc_error__count', 'klayout__drc_error__count',
        'design__lvs_error__count', 'route__antenna_violation__count',
        'antenna__violating__nets', 'antenna__violating__pins']
summary = {'run': str(run), 'last_completed_step': states[-1].parent.name if states else None,
           'has_final_metrics': final_metrics.exists(),
           'flow_reached_manufacturability_report': any(
               p.parent.name.endswith('-misc-reportmanufacturability') for p in states),
           'metrics_note': 'State metrics can be inherited from earlier stages; final physical checks must be present before declaring a pass.',
           'metrics': {k: metrics.get(k) for k in keys},
           'artifacts': [str(p.relative_to(run)) for p in (run / 'final').glob('**/*')
                         if p.is_file() and p.suffix in ('.gds', '.def', '.spef', '.sdf', '.v')]}
timing_states = [p for p in states if '-sta' in p.parent.name]
summary['last_timing_step'] = timing_states[-1].parent.name if timing_states else None
incomplete_record = run / 'verification/incomplete-checks.json'
if incomplete_record.exists():
    summary['recorded_incomplete_checks'] = json.loads(incomplete_record.read_text())
summary['fresh_timing_metrics'] = {}
summary['fresh_physical_checks'] = {}
for suffix, selected in [
        ('-openroad-detailedrouting', ['route__drc_errors', 'route__wirelength']),
        ('-odb-reportdisconnectedpins', ['design__disconnected_pin__count',
                                       'design__critical_disconnected_pin__count'])]:
    candidates = [p for p in states if p.parent.name.endswith(suffix)]
    if candidates:
        path = candidates[-1].parent / 'or_metrics_out.json'
        if path.exists():
            raw = json.loads(path.read_text())
            summary['fresh_physical_checks'][str(path.relative_to(run))] = {
                k: raw[k] for k in selected if k in raw}
antenna_states = [p for p in states if '-openroad-checkantennas' in p.parent.name]
if antenna_states:
    path = antenna_states[-1].parent / 'or_metrics_out.json'
    if path.exists():
        raw = json.loads(path.read_text())
        summary['fresh_physical_checks'][str(path.relative_to(run))] = {
            k: raw[k] for k in ['antenna__violating__nets',
                               'antenna__violating__pins'] if k in raw}
        summary['antenna_metrics_note'] = (
            'Use fresh antenna net/pin counts. The legacy '
            'route__antenna_violation__count may remain inherited from global routing.')
if timing_states:
    for path in timing_states[-1].parent.rglob('or_metrics_out.json'):
        raw = json.loads(path.read_text())
        summary['fresh_timing_metrics'][str(path.relative_to(run))] = {
            k: v for k, v in raw.items()
            if k.startswith('timing__') or k.startswith('design__max_')
        }
    # Standalone OpenSTA emits metrics in its per-corner log, unlike the
    # OpenROAD-based intermediate STA step's or_metrics_out.json.
    for path in timing_states[-1].parent.glob('*/sta.log'):
        raw = {}
        with path.open() as log:
            for line in log:
                if not line.startswith(('%OL_METRIC_I ', '%OL_METRIC_F ')):
                    continue
                kind, key, value = line.split(maxsplit=2)
                if key.startswith(('timing__', 'design__max_')):
                    raw[key] = int(value) if kind.endswith('_I') else float(value)
        if raw:
            summary['fresh_timing_metrics'][str(path.relative_to(run))] = raw
config = json.loads((run / 'resolved.json').read_text())
summary['conditions'] = {k: config.get(k) for k in
    ['PDK', 'STD_CELL_LIBRARY', 'CLOCK_PERIOD', 'DIE_AREA', 'CORE_AREA',
     'USE_SLANG', 'STA_CORNERS', 'STA_THREADS', 'GRT_ANTENNA_REPAIR_DIODE_ONLY']}
summary['rtl_sha256'] = {}
for value in config.get('VERILOG_FILES', []):
    p = Path(value)
    if p.exists():
        summary['rtl_sha256'][value] = hashlib.sha256(p.read_bytes()).hexdigest()
print(json.dumps(summary, indent=2))

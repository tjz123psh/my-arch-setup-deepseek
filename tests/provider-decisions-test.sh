#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python - "$root" <<'PY'
import csv
import sys
from collections import defaultdict
from pathlib import Path

root=Path(sys.argv[1])
path=root/'manifests/provider-decisions.tsv'
if not path.is_file() or path.is_symlink():
    raise SystemExit('provider decision manifest is missing or unsafe')
lines=path.read_text().splitlines()
if not lines or lines[0] != '# schema=1':
    raise SystemExit('provider decision manifest has an unsupported schema')
rows=[]
seen=set()
for line_number,parts in enumerate(csv.reader(lines[1:],delimiter='\t'),2):
    if not parts or not parts[0] or parts[0].startswith('#'): continue
    if len(parts)!=8 or not all(parts):
        raise SystemExit(f'invalid provider decision row at line {line_number}')
    capability,package,channel,repository,decision,exclusive_group,replacement,reason=parts
    if (capability,package) in seen: raise SystemExit(f'duplicate provider candidate: {capability}/{package}')
    seen.add((capability,package))
    if decision not in {'selected','rejected','observed-rejected','manual-deferred'}:
        raise SystemExit(f'invalid provider decision: {capability}/{package}: {decision}')
    if any(ord(c)<32 for c in reason): raise SystemExit(f'control character in provider reason: {package}')
    rows.append(dict(capability=capability,package=package,channel=channel,repository=repository,decision=decision,group=exclusive_group,replacement=replacement))
by_cap=defaultdict(list)
for row in rows: by_cap[row['capability']].append(row)
for capability,candidates in by_cap.items():
    selected=[r for r in candidates if r['decision']=='selected']
    groups={r['group'] for r in candidates if r['group']!='-'}
    if groups and len(selected)>1:
        raise SystemExit(f'exclusive provider capability selects multiple candidates: {capability}')

def decision(capability,package):
    matches=[r for r in rows if r['capability']==capability and r['package']==package]
    if len(matches)!=1: raise SystemExit(f'missing provider decision: {capability}/{package}')
    return matches[0]
if decision('fuzzel-launcher','fuzzel-ime-git')['decision']!='selected': raise SystemExit('IME Fuzzel provider is not selected')
if decision('fuzzel-launcher','fuzzel')['decision']!='rejected': raise SystemExit('official Fuzzel fallback is not explicitly rejected')
if decision('notification-owner','dms-shell')['decision']!='selected': raise SystemExit('DMS notification owner is not selected')
if decision('notification-owner','mako')['decision']!='rejected': raise SystemExit('stale Mako notification owner is not rejected')
if decision('login-manager','sddm')['decision']!='rejected': raise SystemExit('SDDM fallback rejection is missing')
if decision('dms-greeter','greetd-dms-greeter-git')['decision']!='observed-rejected': raise SystemExit('rolling greeter source is not rejected')
policy={}
for parts in csv.reader((root/'manifests/workstation-packages.tsv').read_text().splitlines()[1:],delimiter='\t'):
    if parts and parts[0] and not parts[0].startswith('#'): policy[parts[0]]=parts
for rejected in ('fuzzel','mako','sddm'):
    if rejected in policy: raise SystemExit(f'rejected provider leaked into target policy: {rejected}')
if 'fuzzel-ime-git' not in policy: raise SystemExit('selected Fuzzel provider is absent from target policy')
official_targets=set()
for parts in csv.reader((root/'manifests/official-packages.tsv').read_text().splitlines()[1:],delimiter='\t'):
    if parts and parts[0] and not parts[0].startswith('#'): official_targets.add(parts[2])
for rejected in ('fuzzel','mako','sddm'):
    if rejected in official_targets: raise SystemExit(f'rejected provider remains executable in starter official manifest: {rejected}')
mapping_targets={parts[3] for parts in csv.reader((root/'manifests/config-mappings.tsv').read_text().splitlines()[1:],delimiter='\t') if parts and parts[0] and not parts[0].startswith('#')}
if '.config/mako/config' in mapping_targets:
    raise SystemExit('rejected Mako provider still deploys orphan configuration')
if (root/'config/home/.config/mako/config').exists():
    raise SystemExit('rejected Mako provider still has deployable payload')
print(f'Provider decision checks passed: capabilities={len(by_cap)} rows={len(rows)}')
PY

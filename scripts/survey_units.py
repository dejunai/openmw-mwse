#!/usr/bin/env python3
"""Build units.json from the survey result files (dej (dejunai))."""
import json, glob, os, re
S = '/workspace/survey'
ENGINE_MODS = {'builtin', 'test_lua_api', 'morrowind_tests'}
ENGINE_REPOS = {'github__acidpointer__openmw-enhanced', 'github__Claus-Raphael-Brueckner__openmw-portal', 'github__Fetcher-Simulator__Fetcher-Simulator', 'gitlab__openmw-validator', 'gitlab__vanilla-inspired-water-for-openmw', 'github__Njurse__idle-openmw-android', 'github__lowgraph__openmw-decompiler', 'github__loragea__headless-mp-rig'}
TEST_RX = re.compile(r'test|smoke|selfcheck|enginelab|example|dump|orchestrator|sandbox', re.I)
NEXUS = {'ammo-count-hud': 58307, 'horizontal-compass': 58214, 'no-fires-in-bad-weather': 57579, 'no-more-excessive-healing': 58337,
         'player-on-fire': 58345, 'skyrim-style-quest-notifications': 54148, 'thieves-pickpocket': 58362, 'vaults-restricted': 58405,
         'wildlife-attacks-npcs-too': 54448, 'leave-the-lights-off': 57510}
def url_for(ident):
    i = ident
    if i.startswith('x__'): i = i[3:]
    if i.startswith('github__'):
        o, r = i[8:].split('__', 1); return f'https://github.com/{o}/{r}'
    if i.startswith('gitlab__'):
        rest = i[8:]
        if '__' in rest:
            o, r = rest.split('__', 1); return f'https://gitlab.com/{o}/{r}'
        return f'https://gitlab.com/modding-openmw/{rest}'
    if i.startswith('corpus__') or i.startswith('ref__'):
        n = i.split('__', 1)[1]
        return f'https://www.nexusmods.com/morrowind/mods/{NEXUS[n]}' if n in NEXUS else ''
    return ''
units = []; runs = []
def add_dir(out, prefix_filter=None):
    for r in json.load(open(f'{S}/{out}/runs.json')):
        ident = r['id']
        if out.endswith('_corpus'):
            n = ident.split('__', 1)[1]
            if n not in NEXUS: continue   # git-sourced corpus mods are covered by their fresh clones
        res = json.load(open(f'{S}/{out}/results/{ident}.json'))
        scan = {}
        try: scan = json.load(open(f'{S}/{out}/scan/{ident}.json'))
        except Exception: pass
        runs.append({'id': ident, 'exit': res['exit_code'], 'verdict': res['verdict'], 'errors': res['errors']})
        multi = [e for e in res['errors'] if 'different source folders' in e.get('message', '')]
        if multi:
            vs = sorted(glob.glob(f'{S}/out050/variants/{ident}#*.json'))
            if not vs: continue
            variants = []
            for v in vs:
                d = json.load(open(v)); lab = os.path.basename(v)[len(ident) + 1:-5]
                variants.append((lab, d))
            # light-hotkey / pharis / carefree / corpus: keep only the primary (current) variant
            if len(variants) > 1 and ident.endswith(('light-hotkey', 'pharis-magicka-regeneration', 'carefree_leveling')):
                keep = [x for x in variants if x[0] in ('..', '0.49 or later')]
                variants = keep or variants[:1]
            for lab, d in variants:
                for m in d['mods']:
                    units.append(dict(id=f'{ident}:{m["name"]}', repo=ident, mod=m['name'], variant=lab, verdict=m['verdict'], blockers=m['blockers'], url=url_for(ident), exit=d['exit_code'], scan=scan))
            continue
        if not res['mods']:
            units.append(dict(id=ident, repo=ident, mod=ident, variant='', verdict=res['verdict'], blockers=res['blockers'], url=url_for(ident), exit=res['exit_code'], errors=res['errors'], scan=scan))
            continue
        for m in res['mods']:
            units.append(dict(id=f'{ident}:{m["name"]}', repo=ident, mod=m['name'], variant='', verdict=m['verdict'], blockers=m['blockers'], url=url_for(ident), exit=res['exit_code'], scan=scan))
for o in ('out050', 'out050_corpus', 'out050_extra', 'out050_ref'): add_dir(o)
for u in units:
    r = u['repo']; r_plain = r
    u['counted'] = not (u['mod'] in ENGINE_MODS or r in ENGINE_REPOS or TEST_RX.search(u['mod']))
    if u['verdict'] == 'failed': u['counted'] = False
    if u['verdict'] == 'no-lua': u['counted'] = False
# dedupe by normalised mod name; prefer the canonical host (modding-openmw, then a non-x__ checkout)
def _src_quality(u):
    url = u.get('url') or ''
    repo = u['repo']
    score = 0
    if 'gitlab.com/modding-openmw/' in url or 'github.com/modding-openmw/' in url:
        score += 8
    if not repo.startswith('x__'):
        score += 4
    if repo.startswith('gitlab__') or repo.startswith('github__'):
        score += 1
    return score
by_key = {}
for u in units:
    if not u['counted']:
        continue
    k = re.sub(r'[^a-z0-9]', '', u['mod'].lower())
    if k not in by_key:
        by_key[k] = u
        continue
    prev = by_key[k]
    if prev['repo'] == u['repo']:
        continue
    if _src_quality(u) > _src_quality(prev):
        prev['counted'] = False
        prev['dup_of'] = u['id']
        by_key[k] = u
    else:
        u['counted'] = False
        u['dup_of'] = prev['id']
for u in units: u.pop('scan', None) if False else None
json.dump([{k: v for k, v in u.items() if k != 'scan'} for u in units], open(f'{S}/units.json', 'w'), indent=1)
json.dump(runs, open(f'{S}/runs_all.json', 'w'), indent=1)
print(len(units), sum(u['counted'] for u in units))
import collections
print(collections.Counter(u['verdict'] for u in units if u['counted']))
print('dups:', [(u['id'], u['dup_of']) for u in units if 'dup_of' in u])
print('uncounted:', [(u['id'], u['verdict']) for u in units if not u['counted'] and 'dup_of' not in u])

#!/usr/bin/env python3
"""Aggregate omw2mwse dry-run survey results (credit: dej (dejunai)).

Input: a survey dir with units.json built by build_units (see survey_units.py output) --
this script only reads JSON result files; it never writes outside --out.
"""
import json, re, sys, collections, itertools
from pathlib import Path

def norm_blocker(b):
    b = re.sub(r' \(\d+x\)$', '', b)
    m = re.match(r'requires unsupported module (\S+)$', b)
    if m: return ('module', m.group(1))
    m = re.match(r'unsupported API (\S+)$', b)
    if m: return ('api', m.group(1))
    m = re.match(r'script flag (\w+) not hosted', b)
    if m: return ('flag', m.group(1))
    m = re.match(r'unsupported engine handler (\S+)$', b)
    if m: return ('handler', m.group(1))
    m = re.match(r'.*: (\S+) is only available to player scripts, but this file runs as menu', b)
    if m: return ('menuscope', m.group(1))
    return ('other', b)

FAMILIES = [
 (r'^openmw\.animation|^openmw\.interfaces\.AnimationController', 'animation (openmw.animation, I.AnimationController)'),
 (r'^openmw\.camera|^openmw\.interfaces\.Camera', 'camera (openmw.camera, I.Camera)'),
 (r'^openmw\.postprocessing', 'postprocessing'),
 (r'^openmw\.menu|sendMenuEvent', 'openmw.menu / menu events'),
 (r'^openmw\.ui\.|^openmw\.ui$|^openmw\.interfaces\.MWUI|^openmw_aux\.ui', 'ui layouts (openmw.ui widgets, I.MWUI templates, openmw_aux.ui)'),
 (r'^openmw\.interfaces\.UI', 'I.UI (modes, HUD visibility)'),
 (r'^openmw\.input\.|^openmw\.interfaces\.GamepadControls', 'input (triggers, controller buttons, action handlers)'),
 (r'^openmw\.core\.magic|^openmw\.types\.Actor\.(activeEffects|activeSpells|spells|getSelectedSpell|getSelectedEnchantedItem|setSelectedSpell|setSelectedEnchantedItem|clearSelectedCastable)|^openmw\.types\.(Player|NPC)\.(spells)', 'magic (core.magic records/enums, Actor spells/activeSpells/activeEffects/selected spell)'),
 (r'^openmw\.interfaces\.Combat', 'I.Combat (onHit handlers)'),
 (r'^openmw\.self\.controls', 'self.controls (movement writes)'),
 (r'^openmw\.content|^openmw\.markup|^openmw\.debug', 'content / markup / debug modules'),
 (r'^openmw\.interfaces\.SkillProgression|^openmw\.core\.stats\.(Skill|Attribute)|^openmw\.types\.NPC\.(races|classes)|^openmw\.types\.Player\.(getSkill|stats)', 'skills / stats records (core.stats Skill+Attribute records, NPC races/classes, I.SkillProgression)'),
]
def family(kind, name):
    key = name
    if kind in ('flag',): return 'script kind %s (not hosted)' % name
    if kind == 'menuscope': return 'script kind MENU (not hosted)'
    if kind == 'handler': return 'engine handler %s' % name
    for rx, fam in FAMILIES:
        if re.search(rx, key): return fam
    if kind == 'module': return 'module %s' % name
    if kind == 'api':
        return 'api ' + name
    return 'other: ' + name[:80]

def main(units_path, out_dir):
    units = json.load(open(units_path))
    out = Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    real = [u for u in units if u['counted']]
    verdicts = collections.Counter(u['verdict'] for u in real)
    # fine gaps
    def gapsets(level):
        res = {}
        for u in real:
            if u['verdict'] != 'blocked': continue
            s = set()
            for b in u['blockers']:
                k, n = norm_blocker(b)
                s.add(('fine', k, n) if level == 'fine' else ('fam', family(k, n)))
            res[u['id']] = s
        return res
    out_data = {'verdicts': dict(verdicts), 'n': len(real)}
    for level in ('fine', 'fam'):
        gs = gapsets(level)
        allgaps = collections.Counter(g for s in gs.values() for g in s)
        rows = []
        for g, n in allgaps.items():
            unlock = [i for i, s in gs.items() if s == {g}]
            near = [i for i, s in gs.items() if g in s and len(s) == 2]
            rows.append({'gap': g[-1] if level == 'fam' else g[1] + ' ' + g[2], 'blocks': n, 'alone_unlocks': unlock, 'near': near})
        rows.sort(key=lambda r: (-r['blocks'], -len(r['alone_unlocks'])))
        out_data[level] = rows
        # greedy: pick gap that maximizes number of mods becoming ready given chosen set
        chosen = []; remaining = dict(gs); chosen_set = set(); steps = []
        ready_now = set()
        for _ in range(8):
            best = None
            for g in allgaps:
                if g in chosen_set: continue
                cs = chosen_set | {g}
                gain = [i for i, s in gs.items() if s <= cs and i not in ready_now]
                if best is None or len(gain) > len(best[1]) or (len(gain) == len(best[1]) and allgaps[g] > allgaps[best[0]]):
                    best = (g, gain)
            if not best: break
            chosen_set.add(best[0]); ready_now |= set(best[1])
            steps.append({'add': best[0][-1] if level == 'fam' else best[0][1] + ' ' + best[0][2], 'new_ready': best[1], 'cumulative_ready': len(ready_now)})
        out_data['greedy_' + level] = steps
    # scenario: the runtime already degrades these quietly (0.4.2 animation stubs, 0.4.3 controls writes),
    # but manifest.json still lists them as unsupported, so the scan/convert gate blocks on them
    LAG = ('animation (openmw.animation, I.AnimationController)', 'self.controls (movement writes)')
    lag = []
    for u in real:
        if u['verdict'] != 'blocked': continue
        fams = {family(*norm_blocker(b)) for b in u['blockers']}
        if fams and fams <= set(LAG): lag.append(u['id'])
    out_data['manifest_lag_unlocks'] = lag
    out_data['manifest_lag_blocked_by_any'] = [u['id'] for u in real if u['verdict'] == 'blocked' and any(family(*norm_blocker(b)) in LAG for b in u['blockers'])]
    json.dump(out_data, open(out / 'aggregate.json', 'w'), indent=1)
    return out_data

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

def scope_view(units_path, out_dir, exclude=('ui layouts (openmw.ui widgets, I.MWUI templates, openmw_aux.ui)',)):
    """Greedy ranking without the mods that need UI layouts (Dej's HUD/UI rule keeps those out of scope),
    plus how many gap-families each blocked mod needs."""
    units = [u for u in json.load(open(units_path)) if u['counted']]
    fams = {}
    for u in units:
        if u['verdict'] != 'blocked': continue
        fams[u['id']] = {family(*norm_blocker(b)) for b in u['blockers']}
    dist = collections.Counter(len(s) for s in fams.values())
    inscope = {i: s for i, s in fams.items() if not (s & set(exclude))}
    single = collections.Counter(next(iter(s)) for s in fams.values() if len(s) == 1)
    allg = collections.Counter(g for s in inscope.values() for g in s)
    chosen = set(); ready = set(); steps = []
    for _ in range(10):
        best = None
        for g in allg:
            if g in chosen: continue
            gain = [i for i, s in inscope.items() if s <= chosen | {g} and i not in ready]
            if best is None or len(gain) > len(best[1]) or (len(gain) == len(best[1]) and allg[g] > allg[best[0]]):
                best = (g, gain)
        if not best or not best[1] and steps and not steps[-1]['new_ready']: break
        chosen.add(best[0]); ready |= set(best[1])
        steps.append({'add': best[0], 'new_ready': best[1], 'cumulative_ready': len(ready)})
    # within-reach: mods needing exactly two or fewer families
    res = {'families_needed_distribution': dict(sorted(dist.items())), 'single_family_blockers': dict(single),
           'inscope_blocked': len(inscope), 'greedy_inscope': steps,
           'inscope_family_counts': allg.most_common(25)}
    json.dump(res, open(Path(out_dir) / 'scope_view.json', 'w'), indent=1)
    return res

if __name__ == '__main__':
    scope_view(sys.argv[1], sys.argv[2])

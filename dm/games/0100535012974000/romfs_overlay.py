#!/usr/bin/env python3
# Hades (0100535012974000): the RomFS overlay of the wide view, written by the NSP script from the player's own game files (scripts/build_ipa_from_nsp.py runs a profile's
# romfs_overlay.py; the Mac host takes the folder as DM_ROMFS_OVERLAY, the IPA packs its files over the RomFS). Nothing from the game is in this repository: the script reads
# the files and rewrites them.
# It is the Lua and SJSON half of the PC mod Hephaistos (https://github.com/nbusseneau/hephaistos, MIT licence, Copyright (c) 2021 Nicolas Busseneau; its Lua mod is the
# hephaistos/ folder beside this file, with its licence), whose engine half is the wide view stubs of patches.py:
#   - the Lua mod goes to Content/Mods/Hephaistos/ and Content/Scripts/RoomManager.lua imports it, as Hephaistos installs it. It reads the logical screen from the engine
#     when the game runs (hephaistos/HephaistosConfig.lua), where Hephaistos writes the width it patched;
#   - the SJSON files Hephaistos patches (GUI layouts, full-screen animations, the trait tray decor) get its changes for a wider screen (hor+, the HUD expanded, Hephaistos'
#     default): what it moves to stay centred, what it moves to stay at the right edge, the widths and horizontal scales it stretches across the screen. Hephaistos writes
#     numbers for one width; here each such number is marked instead (patches.py sjson_marks: the original less m x 1,000,000; m = 1 centred, 2 at the right edge or a full
#     width, 3 a scale), and the engine adds the extra width it actually has when it loads the file, so one overlay works at any aspect, and changes nothing at 16:9.
# Written only for a build with the wide view stubs (WIDE_VIEW in main's rewriter table): elsewhere a marked number would be read as it is.
# Usage: romfs_overlay.py <RomFS folder> <rewritten modules folder> <out folder>   (the out folder is emptied first; nothing is written without the stubs)
import re, shutil, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MOD = 'Content/Mods/Hephaistos'
HOOK = 'Content/Scripts/RoomManager.lua'
IMPORT = 'Import "../Mods/Hephaistos/Hephaistos.lua"'

# ---- What Hephaistos changes in the SJSON files (hephaistos/patchers.py SJON_PATCHES), for hor+ with the HUD expanded ----
# GUI/<screen>.sjson: the screen's components; a bare name is recentred (X moves with the centre: m = 1), name:R stays at the right edge (X, m = 2), name:W spans the screen
# (Width, m = 2). Components Hephaistos keeps at the left edge and every Y (the height stays 1080) are unchanged, so they are not listed
GUI = {
    'AboutScreen': 'Back:W AnimatedBackground TitleText UpArrow DownArrow CreditText CancelButton',
    'AnnouncementScreen': 'Back:W AnimatedBackground TitleText SubHeader UpArrow DownArrow AnnouncementText CancelButton',
    'CloudSaveUploadDialog': 'AnimatedBackground TitleText MessageText TextBackground ConfirmButton CancelButton',
    'CloudSettingsScreen': 'Back:W AnimatedBackground TitleText ConnectSteamButton CancelButton DescriptionBox',
    'CloudSyncDialog': 'Back:W AnimatedBackground TitleText MessageText TextBackground ConfirmButton',
    'DebugDrawGroupScreen': 'CancelButton',
    'DebugKeyScreen': 'Back:W LeftArrow CancelButton',
    'DownloadScreen': 'Character ProgressBar ProgressText',
    'ExitConfirmDialog': 'Back:W AnimatedBackground TitleText PromptText TextBackground ConfirmButton CancelButton',
    'InGameUI': 'UseText:W SubtitlesABacking SubtitlesBBacking BuildNumberText:R ElapsedRunTimeText:R SaveAnim:R',
    'KeyMappingScreen': 'Back:W AnimatedBackground AnimatedBackgroundTop TitleText ControlLabel InfoPanel InfoText DefaultsButton RemapInstructions CancelButton',
    'LanguageScreen': 'Back:W AnimatedBackground TitleText LanguageButton CancelButton',
    'LaunchScreen': 'AnimatedBackground ProgressBar WorkText DebugHintText',
    'LoadMapScreen': 'Back:W LeftArrow AlphabeticalSortButton ChronologicalSortButton CancelButton',
    'LoadReplayScreen': 'CancelButton',
    'LoadSaveScreen': 'Back:W CancelButton LeftArrow AlphabeticalSortButton ChronologicalSortButton LoadSpinner NotableSaveInfo RareFormat',
    'LoadScreen': 'AnimatedBackground ProgressBar',
    'MainMenuScreen': 'Front:W AnimatedBackground Logo Character UpdateTitleBacking FullScreenFade PlayGameButton NextUpdateButton UpdateTitleText FeedbackButton',
    'MenuScreen': 'InfoPanel',
    'MessageDialog': 'Back:W AnimatedBackground TitleText MessageText TextBackground ConfirmButton',
    'MessageDialogLarge': 'Back:W AnimatedBackground TitleText MessageText TextBackground ConfirmButton',
    'MiscSettingsScreen': 'Back:W AnimatedBackground TitleText BrightnessLabel BrightnessSlider MasterLabel MasterSlider DescriptionBox InfoPanel InfoText CancelButton XButton',
    'PatchNotesScreen': 'Back:W AnimatedBackground TitleText SubHeader ScrollBar ScrollBarTracker UpArrow DownArrow AnnouncementText CancelButton',
    'PauseScreen': 'Back:W AnimatedBackground TitleText ResumeGameButton LastSaveTimeHint',
    'ProfileScreen': 'Back:W AnimatedBackground FullScreenFade TitleText ContinueGameButton SaveSpinnerHint InstructionHint ProfileButton HardModeButton DeleteButton InfoPanel '
                     'InfoText CancelButton',
    'RemoteProfileScreen': 'Back:W AnimatedBackground FullScreenFade TitleText ContinueGameButton SaveSpinnerHint InstructionHint ProfileButton HardModeButton DeleteButton '
                           'InfoPanel InfoText CancelButton',
    'ResolutionScreen': 'Back:W AnimatedBackground TitleText ResolutionButton ConfirmButton CancelButton',
    'SettingsMenuScreen': 'Back:W AnimatedBackground TitleText SettingsButton CancelButton',
    'StartNewGameScreen': 'Back:W AnimatedBackground FullScreenFade TitleText StartNewGameHint ConfirmButton SubtitlesButton DescriptionBox CancelButton',
    'SVNLockDialog': 'AnimatedBackground TitleText PromptText TextBackground ConfirmButton CancelButton XButton',
    'ThreeWayDialog': 'Back:W AnimatedBackground TitleText PromptText TextBackground ConfirmButton ConfirmAlternateButton CancelButton',
}
# GUI/Platform/NX/<screen>.sjson: the Switch's own changes to some of these screens (it inherits the rest from GUI/), which Hephaistos does not know: the components above that it
# sets again get the same change, and its own info button of the three-way dialog is recentred with the dialog
NX_EXTRA = {'ThreeWayDialog': 'InfoButton'}
# Animations/<file>.sjson: full-screen overlays (vignettes, flashes, transitions) stretched across the screen: the named animation's ScaleX (default 1) times the logical
# width / 1920 (m = 3); name:XY scales ScaleX and ScaleY by it, name:S its Scale (Hephaistos: RoomTransitionIn does not follow ScaleY)
ANIMATIONS = {
    'Fx': 'LavaVignetteA PoisonVignetteLoop HadesBloodstoneVignette FullscreenAlertDisplace BoonInteractDisplace FullscreenChaosDisplace FullscreenChaosDisplaceRings:XY '
          'FullscreenAlertColor FullscreenAlertColorDark FullscreenAlertColorInvert LegendaryAspectSnow WeaponKitProphecyStreaks WeaponKitInteractVignette '
          'WeaponKitInteractVignetteOverlay WrathPresentationStreak WrathPresentationBottomDivider WrathVignette',
    'GUIAnimations': 'BloodFrame LowHealthShroud RoomTransitionIn:S RoomTransitionInBlack RoomTransitionInBoatRide RoomTransitionOutBoatRide DialogueBackgroundIn VignetteOverlay '
                     'EndCreditsVignette',
}
# Obstacles/GUI.sjson: the trait tray's bottom decor follows its tray to the right (Thing.OffsetX, default 0, m = 2)
TRAY = ' '.join(f'TraitTrayDecor_{g}' for g in 'Artemis Chaos Music Hades Chthonic Blood Heat Stone Love'.split())

UNIT, MARK_BELOW = 1_000_000, -500_000
def mark_move(v, m): return v - m * UNIT                      # the engine adds m x half the extra width back
def mark_scale(s):
    assert -40 < s < 40, s
    return -3 * UNIT + 10_000 * s                             # the engine takes the scale times the logical width / 1920
def num(v):   # always with a decimal point: the engine's SJSON reader parses it as a double, where patches.py decodes the marks
    t = f'{v:.4f}'.rstrip('0')
    return t + '0' if t.endswith('.') else t

# ---- SJSON: objects { key = value }, arrays [ value ... ], strings, bare words and numbers, // and /* */ comments. Parsed with positions so edits keep everything else ----
TOKEN = re.compile(r'\s+|//[^\n]*|/\*.*?\*/|"[^"]*"|[{}\[\]=,]|[^\s{}\[\]=,"]+', re.S)
class Node:
    def __init__(self, kind, start): self.kind, self.start, self.end, self.items = kind, start, None, ({} if kind == 'obj' else [])
def parse(text):
    toks = [(m.start(), m.end(), m.group()) for m in TOKEN.finditer(text) if not m.group()[0].isspace() and not m.group().startswith(('//', '/*'))]
    pos = 0
    def value():
        nonlocal pos
        s, e, t = toks[pos]; pos += 1
        if t in '{[':
            n = Node('obj' if t == '{' else 'arr', s)
            while True:
                if toks[pos][2] == ',': pos += 1; continue
                if toks[pos][2] in '}]': n.end = toks[pos][0]; pos += 1; return n
                if n.kind == 'arr': n.items.append(value()); continue
                k = toks[pos][2].strip('"'); assert toks[pos + 1][2] == '=', (k, toks[pos + 1]); pos += 2
                n.items[k] = value()
        n = Node('val', s); n.end, n.text = e, t
        return n
    root = value()
    assert pos == len(toks), 'trailing tokens'
    return root
def number(n):
    try: return float(n.text)
    except (AttributeError, ValueError): return None

class Edits:
    def __init__(self, text): self.text, self.at, self.nl = text, [], '\r\n' if '\r\n' in text else '\n'
    def set(self, node, v): self.at.append((node.start, node.end, num(v)))
    def insert(self, obj, line):   # a key = value line before the object's closing brace, indented one step more than the brace
        bol = self.text.rfind('\n', 0, obj.end) + 1; ind = self.text[bol:obj.end]
        if ind.strip(): self.at.append((obj.end, obj.end, f' {line.strip()} ')); return
        self.at.append((bol, bol, f'{ind}{line}'.replace('\n', self.nl)))
    def apply(self):
        out, last = [], 0
        for s, e, t in sorted(self.at, key=lambda x: (x[0], x[1])):
            assert s >= last, 'overlapping edits'
            out += [self.text[last:s], t]; last = e
        return ''.join(out + [self.text[last:]])
def move(ed, obj, key, m, default=None, where=''):
    n = obj.items.get(key)
    if n is None:
        if default is None: return 0   # Hephaistos fails on a missing key; this build has every one, and a later one without it keeps its place
        ed.insert(obj, f'  {key} = {num(mark_move(default, m))}\n'); return 1
    v = number(n); assert v is not None, f'{where}.{key} is not a number'
    ed.set(n, mark_move(v, m)); return 1
def scale(ed, obj, key, where=''):
    n = obj.items.get(key)
    if n is None: ed.insert(obj, f'  {key} = {num(mark_scale(1.0))}\n'); return 1
    v = number(n); assert v is not None, f'{where}.{key} is not a number'
    ed.set(n, mark_scale(v)); return 1

def gui_file(text, screen, spec, only_present=False):
    root, ed, n = parse(text), Edits(text), 0
    comps = root.items[screen].items
    for c in spec.split():
        name, _, how = c.partition(':')
        if name not in comps:
            if only_present: continue
            sys.exit(f'[RED] GUI/{screen}.sjson has no {name}: not the files Hephaistos knows')
        n += move(ed, comps[name], 'Width' if how == 'W' else 'X', 2 if how in ('W', 'R') else 1, where=f'{screen}.{name}')
    return ed.apply(), n
def by_name(root, list_key, names):
    found = {}
    for it in root.items[list_key].items:   # the top-level entries only, as Hephaistos patches them
        nm = it.items.get('Name') if it.kind == 'obj' else None
        if nm is not None and nm.text.strip('"') in names: found[nm.text.strip('"')] = it
    missing = set(names) - set(found)
    if missing: sys.exit(f'[RED] no {", ".join(sorted(missing))} in {list_key}: not the files Hephaistos knows')
    return found
def anim_file(text, spec):
    root, ed, n = parse(text), Edits(text), 0
    how = dict(c.partition(':')[::2] for c in spec.split())
    for name, it in by_name(root, 'Animations', how).items():
        for key in {'': ('ScaleX',), 'XY': ('ScaleX', 'ScaleY'), 'S': ('Scale',)}[how[name]]: n += scale(ed, it, key, where=name)
    return ed.apply(), n
def tray_file(text):
    root, ed, n = parse(text), Edits(text), 0
    for name, it in by_name(root, 'Obstacles', TRAY.split()).items():
        thing = it.items.get('Thing')
        if thing is None: ed.insert(it, f'  Thing = {{ OffsetX = {num(mark_move(0, 2))} }}\n'); n += 1
        else: n += move(ed, thing, 'OffsetX', 2, default=0, where=name)
    return ed.apply(), n

def unmarked(romfs):   # the marks must not meet a number of the game's own: none of its SJSON numbers is below -500,000
    for p in sorted((romfs / 'Content/Game').rglob('*.sjson')):
        for m in re.finditer(r'=\s*(-\d[\d.]*)', p.read_bytes().decode('utf-8', errors='replace')):
            if float(m.group(1)) < MARK_BELOW: sys.exit(f'[RED] {p.relative_to(romfs)} has {m.group(1)}: the wide view marks could be mistaken for it')

def main(romfs, patched, out):
    romfs, out = Path(romfs), Path(out)
    if out.exists(): shutil.rmtree(out)
    fx = Path(patched) / 'main.fixups.tsv'
    if not fx.is_file() or not re.search(r'^# WIDE_VIEW\t', fx.read_text(), re.M):
        print('no wide view stubs in this build (WIDE_VIEW): no RomFS overlay'); return
    unmarked(romfs)
    bom = {}
    def put(rel, text):   # as read: the same byte order mark and line ends
        p = out / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes((bom.get(rel, '') + text).encode('utf-8'))
    def read(rel):
        t = (romfs / rel).read_bytes().decode('utf-8')
        if t.startswith('\ufeff'): bom[rel], t = '\ufeff', t[1:]
        return t
    hook = read(HOOK)
    nl = '\r\n' if '\r\n' in hook else '\n'
    put(HOOK, hook if IMPORT in hook else hook.rstrip('\r\n') + f'{nl}{nl}-- Hephaistos hook (nxnative wide view){nl}{IMPORT}{nl}')
    lua = sorted(p for p in (HERE / 'hephaistos').rglob('*') if p.is_file())
    for p in lua: put(f'{MOD}/{p.relative_to(HERE / "hephaistos")}', p.read_bytes().decode('utf-8'))
    total = nx = 0
    for screen, spec in GUI.items():
        rel = f'Content/Game/GUI/{screen}.sjson'
        text, n = gui_file(read(rel), screen, spec); put(rel, text); total += n
        rel = f'Content/Game/GUI/Platform/NX/{screen}.sjson'
        if (romfs / rel).is_file():
            text, n = gui_file(read(rel), screen, f'{spec} {NX_EXTRA.get(screen, "")}', only_present=True); put(rel, text); total += n; nx += 1
    for f, spec in ANIMATIONS.items():
        rel = f'Content/Game/Animations/{f}.sjson'
        text, n = anim_file(read(rel), spec); put(rel, text); total += n
    text, n = tray_file(read('Content/Game/Obstacles/GUI.sjson')); put('Content/Game/Obstacles/GUI.sjson', text); total += n
    print(f'wide view RomFS overlay: {out} (the Lua mod, {len(lua)} files; {len(GUI) + nx + len(ANIMATIONS) + 1} SJSON files, {total} numbers marked)')

if __name__ == '__main__':
    if len(sys.argv) != 4: sys.exit('usage: romfs_overlay.py <RomFS folder> <rewritten modules folder> <out folder>')
    main(*sys.argv[1:])

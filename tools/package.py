"""Build a deterministic, install-ready ZIP from the runtime allowlist."""
from pathlib import Path
import re, zipfile, argparse
root = Path(__file__).resolve().parents[1]
addon = root / 'GrindOnly'
parser = argparse.ArgumentParser()
parser.add_argument('--version')
args = parser.parse_args()
toc = (addon / 'GrindOnly.toc').read_text()
version = re.search(r'^## Version: (\d+\.\d+\.\d+)$', toc, re.M).group(1)
if args.version and args.version != version:
    raise SystemExit('Requested version does not match TOC')
files = ['GrindOnly.toc'] + [s.strip() for s in toc.splitlines() if s.strip() and not s.startswith('#')] + ['Media/TacticalPanel.tga','Media/TacticalCard.tga','Media/TacticalHover.tga']
for name in files:
    p = addon / name
    if not p.is_file() or p.is_symlink() or not p.resolve().is_relative_to(addon.resolve()):
        raise SystemExit(f'Invalid runtime file: {name}')
out = root / 'dist' / 'GrindOnly.zip'
out.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for name in sorted(files):
        info = zipfile.ZipInfo('GrindOnly/' + name, (2020,1,1,0,0,0))
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, (addon / name).read_bytes())
with zipfile.ZipFile(out) as z:
    assert z.testzip() is None
    assert set(z.namelist()) == {'GrindOnly/'+n for n in files}
print(f'Packaged v{version}: {out} ({len(files)} files)')

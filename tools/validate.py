from pathlib import Path
import shutil, subprocess
root = Path(__file__).resolve().parents[1]
addon = root / 'GrindOnly'
toc = (addon / 'GrindOnly.toc').read_text().splitlines()
files = [line.strip() for line in toc if line.strip() and not line.startswith('#')]
assert all((addon / name).is_file() for name in files), 'Missing TOC entry'
assert set(files) == {p.name for p in addon.glob('*.lua')}, 'Unexpected Lua file'
assert '## SavedVariables: GrindOnlyDB' in toc
assert not (addon / 'CartmanIcon.tga').exists()
compiler = next((shutil.which(n) for n in ('luac5.1','luac','texluac') if shutil.which(n)), None)
if not compiler:
    raise SystemExit('Install Lua compiler (luac) before validation')
for name in files:
    subprocess.run([compiler, '-p', str(addon / name)], check=True)
print(f'Manifest and {len(files)} Lua syntax checks passed using {compiler}')

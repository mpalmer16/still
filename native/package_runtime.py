"""Make host-built ERTS/NIF libraries independent of the host's Homebrew paths."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import sys

bundle = Path(sys.argv[1]).resolve()
frameworks = bundle / "Contents/Frameworks"
frameworks.mkdir(parents=True, exist_ok=True)
magic_values = {bytes.fromhex(x) for x in ("cffaedfe", "feedfacf", "cafebabe", "cafebabf", "cefaedfe")}

def mach_o(path):
    if not path.is_file():
        return False
    with path.open("rb") as source:
        return source.read(4) in magic_values

pending = [path for path in bundle.rglob("*") if mach_o(path)]
seen = set()
copied = {}
patched = []
while pending:
    binary = pending.pop()
    if binary in seen:
        continue
    seen.add(binary)
    listing = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    dependencies = [line.strip().split(" (")[0] for line in listing.splitlines()[1:]]
    for dependency in dependencies:
        if not dependency.startswith(("/opt/homebrew/", "/usr/local/")):
            continue
        source = Path(dependency).resolve()
        destination = frameworks / source.name
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if destination.name in copied and copied[destination.name] != digest:
            raise RuntimeError(f"Conflicting runtime library names: {destination.name}")
        if destination.name not in copied:
            shutil.copy2(source, destination)
            destination.chmod(0o755)
            copied[destination.name] = digest
            subprocess.check_call(["install_name_tool", "-id", "@loader_path/" + destination.name, str(destination)])
            pending.append(destination)
        relative = os.path.relpath(destination, binary.parent)
        subprocess.check_call(["install_name_tool", "-change", dependency, "@loader_path/" + relative, str(binary)])
        patched.append(binary)

for binary in set(patched) | {frameworks / name for name in copied}:
    subprocess.check_call(["codesign", "--force", "--sign", "-", str(binary)])
print(f"Bundled {len(copied)} host runtime libraries; retained only macOS system dependencies.")

"""Exercise packaged runtime and native lifecycle using only fabricated collections."""
from pathlib import Path
import argparse
import errno
import os
import plistlib
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request

project = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bundle", type=Path, default=project / "dist/Still.app",
                    help="Application bundle to check (defaults to dist/Still.app)")
arguments = parser.parse_args()
bundle = arguments.bundle.expanduser().resolve() / "Contents"
with (bundle / "Info.plist").open("rb") as info:
    executable_name = plistlib.load(info).get("CFBundleExecutable")
if (not isinstance(executable_name, str) or not executable_name
        or "/" in executable_name or executable_name in (".", "..")):
    parser.error("The bundle's CFBundleExecutable must name one executable file")
executable = bundle / "MacOS" / executable_name
guard = bundle / "MacOS/StillBackend"
release = bundle / "Resources/backend/bin/still"

def environment(data, port):
    env = os.environ.copy()
    env.update(STILL_DATA_DIRECTORY=str(data), STILL_NATIVE_PORT=str(port),
               PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    return env

def check(data, port):
    result = subprocess.run([str(executable), "--check-backend"], env=environment(data, port),
                            text=True, capture_output=True, timeout=40)
    if result.returncode:
        raise AssertionError(result.stderr)
    assert "backend ready" in result.stdout
    with socket.socket() as probe:
        assert probe.connect_ex(("127.0.0.1", port)) != 0, "Backend survived ordinary stop"

with tempfile.TemporaryDirectory(prefix="still-native-") as temporary:
    root = Path(temporary)
    empty = root / "empty"
    check(empty, 4050)
    db = sqlite3.connect(empty / "still.db")
    assert db.execute("select count(*) from entries").fetchone()[0] == 0
    assert db.execute("pragma integrity_check").fetchone()[0] == "ok"
    db.close()
    print("Empty collection: bundled backend starts, migrates, answers health, and stops.")
    # WebKit keeps HTTP connections alive. A server closing one during Quit
    # leaves TIME_WAIT on its port, even though no application is listening.
    with socket.socket() as recent:
        recent.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        recent.bind(("127.0.0.1", 0))
        recent.listen()
        recently_closed_port = recent.getsockname()[1]
        with socket.socket() as client:
            client.connect(("127.0.0.1", recently_closed_port))
            connection, _ = recent.accept()
            with connection:
                connection.shutdown(socket.SHUT_WR)
                assert client.recv(1) == b""
    with socket.socket() as plain_probe:
        try:
            plain_probe.bind(("127.0.0.1", recently_closed_port))
        except OSError as error:
            assert error.errno == errno.EADDRINUSE, "Expected the just-closed connection to reserve its port"
        else:
            raise AssertionError("The rapid-reopen regression needs a TIME_WAIT connection")
    check(empty, recently_closed_port)
    check(empty, recently_closed_port)
    print("Rapid reopening: a recently closed connection does not block two immediate launches.")
    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 4050))
        occupied.listen()
        refused = subprocess.run([str(executable), "--check-backend"],
                                 env=environment(empty, 4050), text=True,
                                 capture_output=True, timeout=10)
        assert refused.returncode == 1 and "using Still’s local port" in refused.stderr
    print("Occupied native port: refused rather than attaching to an unrelated local service.")

    established = root / "established"
    established.mkdir()
    source = sqlite3.connect(f"file:{empty / 'still.db'}?mode=ro", uri=True)
    db = sqlite3.connect(established / "still.db")
    source.backup(db)
    source.close()
    stamp = "2020-01-02T03:04:05.000000Z"
    # Populate the freshly migrated empty schema. Never read a personal database.
    rows = [
        (1, "Synthetic:Gear:", "cobalt sprocket\n\tcalibration branch", "before", "fixture-gear", "fixture-sheet", "Early Notebooks/Lists 1", 0, None),
        (2, "Synthetic:Bench:", "saffron prism on the test bench", "now", None, None, None, None, 1),
        (3, "Synthetic:Gauge:", "zircon gauge at fixture position three", "before", "fixture-gauge", "fixture-other", "Early Notebooks/Lists 2", 100, None),
    ]
    for row in rows:
        db.execute("""insert into entries
          (id,title,body,origin,source_key,source_group,notebook,source_order,beside_id,source,inserted_at,updated_at)
          values (?,?,?,?,?,?,?,?,?,'{}',?,?)""", (*row, stamp, stamp))
    db.executemany("insert into versions (entry_id,title,body,inserted_at) values (?,?,?,?)", [
        (1, "Synthetic:Gear:Earlier:", "cobalt sprocket before calibration", stamp),
        (2, "Synthetic:Bench:Earlier:", "saffron prism before alignment", stamp),
    ])
    db.execute("""insert into room_states (id,recent,light,letters,writing_id,draft_beside_id)
                  values (1,'{"ids":[1,3]}',123,65,2,NULL)""")
    db.commit()
    def records(connection):
        return {table: connection.execute(f"select * from {table} order by id").fetchall()
                for table in ("entries", "versions", "room_states")}
    original = records(db)
    assert len(original["entries"]) == 3 and len(original["versions"]) == 2
    db.close()
    check(established, 4050)
    db = sqlite3.connect(established / "still.db")
    assert records(db) == original
    assert db.execute("pragma integrity_check").fetchone()[0] == "ok"
    db.close()
    print("Established synthetic collection: all fields of 3 pieces, 2 earlier versions, and room state preserved through native start/stop.")

    env = environment(established, 4051)
    env.update(DATABASE_PATH=str(established / "still.db"),
               SECRET_KEY_BASE=(established / ".secret_key_base").read_text(),
               PHX_HOST="localhost", PHX_SERVER="true", STILL_NATIVE="true", PORT="4051",
               RELEASE_DISTRIBUTION="none", RELEASE_TMP=str(root), ERL_FLAGS="+S 2:2")
    owner_code = "import subprocess,time; p=subprocess.Popen(" + repr([str(guard), str(release)]) + ",stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(p.pid,flush=True); time.sleep(60)"
    owner = subprocess.Popen(["/usr/bin/python3", "-c", owner_code], env=env,
                             stdout=subprocess.PIPE, text=True)
    guard_pid = int(owner.stdout.readline())
    try:
        for _ in range(100):
            try:
                with urllib.request.urlopen("http://127.0.0.1:4051/healthz", timeout=.2) as response:
                    if response.status == 200: break
            except OSError:
                time.sleep(.1)
        else: raise AssertionError("Guarded backend never became ready")
        owner.kill()
        owner.wait(timeout=3)
        for _ in range(150):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", 4051)) != 0: break
            time.sleep(.1)
        else: raise AssertionError("Backend survived abrupt owner exit")
        print("Abrupt window-owner exit: guard stops its BEAM and closes the local listener.")
    finally:
        if owner.poll() is None: owner.kill(); owner.wait()
        try: os.kill(guard_pid, signal.SIGTERM)
        except ProcessLookupError: pass

print(f"Native backend smoke passed for {arguments.bundle.name} with Homebrew absent from PATH; only synthetic collections used.")

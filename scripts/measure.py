"""Measure one existing MacStatus process without generating CPU load in the app."""
import datetime
import json
import subprocess
import sys
import time

pid, seconds, destination = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]


def reading():
    row = subprocess.check_output(
        ["ps", "-p", str(pid), "-o", "time=,rss="], text=True
    ).split()
    fields = row[0].split(":")
    cpu = float(fields[-1]) + int(fields[-2]) * 60
    if len(fields) == 3:
        cpu += int(fields[0]) * 3600
    return cpu, int(row[1])


before, started = reading(), time.monotonic()
time.sleep(seconds)
after, elapsed = reading(), time.monotonic() - started
vmmap = subprocess.check_output(["vmmap", "-summary", str(pid)], text=True)
footprint = next((line.strip() for line in vmmap.splitlines() if line.startswith("Physical footprint:")), "Unavailable")
report = {
    "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "pid": pid,
    "elapsed_seconds": round(elapsed, 2),
    "cpu_seconds": round(after[0] - before[0], 3),
    "average_cpu_percent_one_core": round((after[0] - before[0]) / elapsed * 100, 3),
    "resident_memory_mib": round(after[1] / 1024, 2),
    "physical_footprint": footprint,
}
with open(destination, "w") as output:
    json.dump(report, output, indent=2)
print(json.dumps(report, indent=2))

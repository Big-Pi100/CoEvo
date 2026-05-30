#!/usr/bin/env python3
"""Read local plan_handler.rs and write to VPS via SSH."""
import subprocess, sys

local_path = "E:/CoEvo/backend/crates/api_server/src/plan_handler.rs"
vps_path = "/tmp/backend/crates/api_server/src/plan_handler.rs"

with open(local_path, "r", encoding="utf-8") as f:
    content = f.read()

# Write via SSH
proc = subprocess.Popen(
    ["ssh", "-i", os.path.expanduser("~/.ssh/coevo_key"),
     "ubuntu@<OLD_VPS_IP>",
     f"cat > {vps_path}"],
    stdin=subprocess.PIPE, text=True
)
proc.communicate(input=content)
print("Uploaded OK" if proc.returncode == 0 else f"Failed: {proc.returncode}")

import os

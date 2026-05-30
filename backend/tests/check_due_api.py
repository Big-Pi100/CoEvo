#!/usr/bin/env python3
import urllib.request, json

API = "http://<OLD_VPS_IP>:8080"

req = urllib.request.Request(API + "/api/auth/login",
    data=json.dumps({"username": "chicn1780138167", "password": "test123"}).encode(),
    headers={"Content-Type": "application/json"}, method="POST")
d = json.loads(urllib.request.urlopen(req).read().decode())
uid = d["user_id"]
token = d["token"]

# Check due cards
req = urllib.request.Request(API + "/api/review/due?user_id=" + uid,
    headers={"Authorization": "Bearer " + token})
d = json.loads(urllib.request.urlopen(req).read().decode())
print("Total due:", d.get("total_due", 0))
cards = d.get("cards", [])
for c in cards:
    print("  front=" + c["front"][:40] + " domain=" + str(c.get("domain","?")) + " type=" + c.get("card_type","?"))

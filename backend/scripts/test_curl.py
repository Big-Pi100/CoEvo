#!/usr/bin/env python3
"""生成正确的签名并用 curl 测试"""
import os, subprocess, json, base64, time
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding

CERT_DIR = r"E:\CoEvo\backend\certs"
MCH_ID = "1114056630"
APP_ID = "wx4f90b0f2c9f46504"
CERT_SERIAL = "7A032EB2A835CC9AD8BAE06C52937ADC21EA1FE9"

with open(os.path.join(CERT_DIR, "apiclient_key.pem"), "rb") as f:
    key = serialization.load_pem_private_key(f.read(), password=None)

method = "POST"
uri = "/v3/pay/transactions/native"
timestamp = str(int(time.time()))
nonce = os.urandom(16).hex()
body = json.dumps({
    "appid": APP_ID,
    "mchid": MCH_ID,
    "description": "test",
    "out_trade_no": f"PYCURL_{int(time.time())}",
    "time_expire": "20260617000000",
    "notify_url": "https://keyievolution.fun/api/pay/notify",
    "amount": {"total": 1, "currency": "CNY"},
}, separators=(",", ":"))

sign_str = f"{method}\n{uri}\n{timestamp}\n{nonce}\n{body}\n"
sig = key.sign(sign_str.encode(), padding.PKCS1v15(), hashes.SHA256())
sig_b64 = base64.b64encode(sig).decode()
auth = f'WECHATPAY2-SHA256-RSA2048 mchid="{MCH_ID}",nonce_str="{nonce}",timestamp="{timestamp}",signature="{sig_b64}"'

print(f"=== 用 Python 生成的签名测试 ===")
print(f"Timestamp: {timestamp}")
print(f"Nonce: {nonce}")
print(f"Body: {body}")
print(f"Sign str: {repr(sign_str)}")
print(f"Auth: {auth[:100]}...")

# Test with merchant cert serial
headers1 = [
    f"Authorization: {auth}",
    "Content-Type: application/json",
    "Accept: application/json",
    "User-Agent: CoEvo/0.1",
    f"Wechatpay-Serial: {CERT_SERIAL}",
]

# Write body to temp file for curl
with open("e:\\tmp\\req_body.txt", "w") as f:
    f.write(body)

cmd1 = f'curl -s -w "\\nHTTP: %{{http_code}}" -X POST "https://api.mch.weixin.qq.com/v3/pay/transactions/native" ' + \
    " ".join(f'-H "{h}"' for h in headers1) + ' -d @"e:\\tmp\\req_body.txt"'
print(f"\n=== CMD: {cmd1[:200]}...")
result = subprocess.run(cmd1, capture_output=True, shell=True)
print(f"Result: {result.stdout.decode()}")

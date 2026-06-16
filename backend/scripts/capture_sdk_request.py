#!/usr/bin/env python3
"""Capture exact request from wechatpayv3 SDK"""
import os, json, logging, uuid, time, base64
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding as asym_padding

logging.basicConfig(level=logging.DEBUG)

CERT_DIR = r"E:\CoEvo\backend\certs"
with open(os.path.join(CERT_DIR, "apiclient_key.pem")) as f:
    private_key_str = f.read()

# 1. 手动构造签名 - 模拟 SDK 内部
method = "POST"
path = "/v3/pay/transactions/native"
mchid = "1114056630"
serial_no = "7A032EB2A835CC9AD8BAE06C52937ADC21EA1FE9"

timestamp = str(int(time.time()))
nonce_str = ''.join(str(uuid.uuid4()).split('-')).upper()

data = {
    "appid": "wx4f90b0f2c9f46504",
    "mchid": "1114056630",
    "description": "test",
    "out_trade_no": f"PYSDK_{int(time.time())}",
    "time_expire": "20260617000000",
    "notify_url": "https://keyievolution.fun/api/pay/notify",
    "amount": {"total": 1, "currency": "CNY"},
}

# SDK 的 json.dumps 不会传 separators 参数 → 带空格
body = json.dumps(data)
print(f"=== SDK JSON body (with spaces) ===")
print(repr(body))

sign_str = f"{method}\n{path}\n{timestamp}\n{nonce_str}\n{body}\n"
print(f"\n=== Sign string ===")
print(repr(sign_str))

# 用 cryptography 签名 - 和 SDK 完全一样
private_key = serialization.load_pem_private_key(
    private_key_str.encode(), password=None)
signature = private_key.sign(
    data=sign_str.encode(),
    padding=asym_padding.PKCS1v15(),
    algorithm=hashes.SHA256()
)
sign_b64 = base64.b64encode(signature).decode().replace('\n', '')

auth = f'WECHATPAY2-SHA256-RSA2048 mchid="{mchid}",nonce_str="{nonce_str}",signature="{sign_b64}",timestamp="{timestamp}",serial_no="{serial_no}"'
wechatpay_serial = "PUB_KEY_ID_0111140566302026061500112156001801"

print(f"\n=== Auth header ===")
print(auth)
print(f"\n=== Wechatpay-Serial ===")
print(wechatpay_serial)

# 用 curl 测试
import subprocess
import tempfile

with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
    f.write(body)
    body_file = f.name

cmd = [
    'curl', '-s', '-w', '\\nHTTP: %{http_code}',
    '-X', 'POST',
    'https://api.mch.weixin.qq.com/v3/pay/transactions/native',
    '-H', f'Authorization: {auth}',
    '-H', 'Content-Type: application/json',
    '-H', f'Wechatpay-Serial: {wechatpay_serial}',
    '-d', body,
]
print(f"\n=== Full curl command ===")
print(' '.join(cmd))

result = subprocess.run(cmd, capture_output=True)
print(f"\n=== Result ===")
print(result.stdout.decode())

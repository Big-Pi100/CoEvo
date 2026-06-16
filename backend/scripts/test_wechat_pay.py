#!/usr/bin/env python3
"""测试微信支付 Native 下单 - 调试用"""
import requests, json, time, os, hashlib, base64
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.backends import default_backend

CERT_DIR = r"E:\CoEvo\backend\certs"
MCH_ID = "1114056630"
APP_ID = "wx4f90b0f2c9f46504"
PUB_KEY_ID = "PUB_KEY_ID_0111140566302026061500112156001801"
API_V3_KEY = "asderoiu234nn34234njoij134i9134n"

# 加载私钥
with open(os.path.join(CERT_DIR, "apiclient_key.pem"), "rb") as f:
    private_key = serialization.load_pem_private_key(f.read(), password=None, backend=default_backend())

# 加载证书获取序列号
with open(os.path.join(CERT_DIR, "apiclient_cert.pem"), "rb") as f:
    cert = serialization.load_pem_x509_certificate(f.read(), default_backend())
cert_serial = format(cert.serial_number, "X")
print(f"证书序列号: {cert_serial}")

# 构建请求
method = "POST"
url = "https://api.mch.weixin.qq.com/v3/pay/transactions/native"
uri = "/v3/pay/transactions/native"
timestamp = str(int(time.time()))
nonce = os.urandom(16).hex()

body = json.dumps({
    "appid": APP_ID,
    "mchid": MCH_ID,
    "description": "test",
    "out_trade_no": f"TEST_{int(time.time())}",
    "time_expire": "20260617000000",
    "notify_url": "https://keyievolution.fun/api/pay/notify",
    "amount": {"total": 1, "currency": "CNY"},
}, separators=(",", ":"))

sign_str = f"{method}\n{uri}\n{timestamp}\n{nonce}\n{body}\n"
print(f"\n=== 签名串 ===")
print(repr(sign_str))

# 方法1: 标准 PKCS1v15 签名 (hash then sign)
signature1 = private_key.sign(
    sign_str.encode(),
    padding.PKCS1v15(),
    hashes.SHA256()
)
sig1_b64 = base64.b64encode(signature1).decode()
auth1 = f'WECHATPAY2-SHA256-RSA2048 mchid="{MCH_ID}",nonce_str="{nonce}",timestamp="{timestamp}",signature="{sig1_b64}"'

# 用证书序列号测试
headers1 = {
    "Authorization": auth1,
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "CoEvo/0.1",
    "Wechatpay-Serial": cert_serial,
}
print(f"\n=== 方法1: 标准签名 + 证书序列号 ===")
r = requests.post(url, headers=headers1, data=body, timeout=10)
print(f"Status: {r.status_code}, Body: {r.text}")

# 用公钥ID测试
headers2 = dict(headers1)
headers2["Wechatpay-Serial"] = PUB_KEY_ID
print(f"\n=== 方法2: 标准签名 + 公钥ID ===")
r = requests.post(url, headers=headers2, data=body, timeout=10)
print(f"Status: {r.status_code}, Body: {r.text}")

# 方法2: 使用 openssl dgst 签名方式 (SHA256 digest first)
# Pkcs1v15Sign in rsa crate expects pre-hashed 32 byte input
digest = hashlib.sha256(sign_str.encode()).digest()
print(f"\n=== SHA256 digest hex: {digest.hex()} ===")

# Try with explicit digest length
signature3 = bytes(private_key.sign(  # type: ignore
    sign_str.encode(),
    padding.PKCS1v15(),
    hashes.SHA256()
))
sig3_b64 = base64.b64encode(signature3).decode()

# Verify with openssl
import subprocess
proc = subprocess.run(
    ["openssl", "dgst", "-sha256", "-verify", "-sigopt", "rsa_padding_mode:pkcs1"],
    input=sign_str.encode(),
    capture_output=True,
)
print(f"OpenSSL verify: {proc.returncode}")

proc2 = subprocess.run(
    ["openssl", "pkeyutl", "-verify", "-pkeyopt", "digest:sha256", "-pkeyopt", "rsa_padding_mode:pkcs1",
     "-pubin", "-inkey", os.path.join(CERT_DIR, "pub_key.pem")],
    input=digest + b"\x00" * 32,  # wrong
    capture_output=True,
)
print(f"pkeyutl test: {proc2.returncode}")

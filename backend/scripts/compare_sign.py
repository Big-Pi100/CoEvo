#!/usr/bin/env python3
"""对比 wechatpayv3 SDK 签名 vs openssl 签名"""
import os, json, base64, hashlib, subprocess, tempfile
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding

CERT_DIR = r"E:\CoEvo\backend\certs"
with open(os.path.join(CERT_DIR, "apiclient_key.pem"), "rb") as f:
    key = serialization.load_pem_private_key(f.read(), password=None)

method = "POST"
uri = "/v3/pay/transactions/native"
timestamp = "1781614600"
nonce = "test_nonce_0000000000000000000"
body = '{"appid":"wx4f90b0f2c9f46504","mchid":"1114056630","description":"test","out_trade_no":"PYTEST_999","time_expire":"20260617000000","notify_url":"https://keyievolution.fun/api/pay/notify","amount":{"total":1,"currency":"CNY"}}'

sign_str = f"{method}\n{uri}\n{timestamp}\n{nonce}\n{body}\n"
print(f"=== Sign string ===")
print(repr(sign_str))

# 方法1: cryptography 标准签名 (hash then sign, PKCS1v15)
sig_crypto = key.sign(
    sign_str.encode(),
    padding.PKCS1v15(),
    hashes.SHA256()
)
sig_crypto_b64 = base64.b64encode(sig_crypto).decode()
print(f"\n=== cryptography 签名 ===")
print(f"len={len(sig_crypto)}, b64={sig_crypto_b64[:50]}...")

# 方法2: openssl dgst -sha256 -sign
proc = subprocess.run(
    ["openssl", "dgst", "-sha256", "-sign", os.path.join(CERT_DIR, "apiclient_key.pem")],
    input=sign_str.encode(),
    capture_output=True,
    shell=True
)
sig_openssl_dgst = proc.stdout
sig_openssl_b64 = base64.b64encode(sig_openssl_dgst).decode()
print(f"\n=== openssl dgst 签名 ===")
print(f"len={len(sig_openssl_dgst)}, b64={sig_openssl_b64[:50]}...")
print(f"Match cryptography: {sig_crypto == sig_openssl_dgst}")

# 方法3: openssl pkeyutl 签名 (先hash再sign)
digest = hashlib.sha256(sign_str.encode()).digest()
tmphash = tempfile.NamedTemporaryFile(delete=False)
tmphash.write(digest)
tmphash.close()
proc2 = subprocess.run(
    ["openssl", "pkeyutl", "-sign", "-pkeyopt", "digest:sha256",
     "-pkeyopt", "rsa_padding_mode:pkcs1",
     "-inkey", os.path.join(CERT_DIR, "apiclient_key.pem"),
     "-in", tmphash.name],
    capture_output=True,
)
sig_pkeyutl = proc2.stdout
sig_pkeyutl_b64 = base64.b64encode(sig_pkeyutl).decode()
print(f"\n=== openssl pkeyutl 签名 ===")
print(f"len={len(sig_pkeyutl)}, b64={sig_pkeyutl_b64[:50]}...")
print(f"Match cryptography: {sig_crypto == sig_pkeyutl}")
os.unlink(tmphash.name)

# 方法4: openssl dgst with base64 (simulating bash)
proc3 = subprocess.run(
    f'echo -n "{sign_str}" | openssl dgst -sha256 -sign "{os.path.join(CERT_DIR, "apiclient_key.pem")}" | openssl base64 -A',
    capture_output=True, shell=True
)
print(f"\n=== shell openssl 签名 ===")
print(f"b64={proc3.stdout.decode().strip()[:50]}...")
print(f"Match cryptography: {proc3.stdout.decode().strip() == sig_crypto_b64}")

print(f"\n=== 用 cryptography 签名验证 ===")
with open(os.path.join(CERT_DIR, "apiclient_cert.pem"), "rb") as f:
    cert = serialization.load_pem_x509_certificate(f.read())
pub = cert.public_key()
try:
    pub.verify(sig_crypto, sign_str.encode(), padding.PKCS1v15(), hashes.SHA256())
    print("✅ 自验通过：自我签名自我验证 OK")
except Exception as e:
    print(f"❌ 自验失败: {e}")

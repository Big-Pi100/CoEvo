"""纯 Python + cryptography 实现微信支付 API v3 平台证书下载"""
import os, json, time, requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from base64 import b64decode, b64encode

CERT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'certs'))

# 加载私钥
with open(os.path.join(CERT_DIR, 'apiclient_key.pem'), 'rb') as f:
    private_key = serialization.load_pem_private_key(f.read(), password=None)

timestamp = str(int(time.time()))
nonce = os.urandom(16).hex()[:32]
method = 'GET'
path = '/v3/certificates'
body = ''

# 构建签名串
sign_str = f"{method}\n{path}\n{timestamp}\n{nonce}\n{body}\n"
print(f"Sign string: {repr(sign_str)}")

# RSA-SHA256 签名
signature = b64encode(
    private_key.sign(sign_str.encode(), padding.PKCS1v15(), hashes.SHA256())
).decode()

# 构建 Authorization
auth = f'WECHATPAY2-SHA256-RSA2048 mchid="1114056630",nonce_str="{nonce}",timestamp="{timestamp}",signature="{signature}"'

headers = {
    'Authorization': auth,
    'Accept': 'application/json',
    'User-Agent': 'CoEvo/0.1',
}

url = f'https://api.mch.weixin.qq.com{path}'
resp = requests.get(url, headers=headers)
print(f"Status: {resp.status_code}")

if resp.status_code == 200:
    data = resp.json()
    api_v3_key = os.environ.get('WECHAT_API_V3_KEY', 'asderoiu234nn34234njoij134i9134n')
    for cert_info in data.get('data', []):
        ec = cert_info['encrypt_certificate']
        # AES-256-GCM 解密
        key = api_v3_key.encode()[:32]
        nonce_bytes = ec['nonce'].encode()[:12]
        aad = ec['associated_data'].encode()
        cipher = Cipher(algorithms.AES(key), modes.GCM(nonce_bytes))
        decryptor = cipher.decryptor()
        decryptor.authenticate_additional_data(aad)
        plain = decryptor.update(b64decode(ec['ciphertext'])) + decryptor.finalize()
        
        cert_path = os.path.join(CERT_DIR, 'wechatpay_platform_cert.pem')
        with open(cert_path, 'wb') as f:
            f.write(plain)
        print(f"✅ 平台证书已保存: {cert_path}")
        print(f"   序列号: {cert_info['serial_no']}")
else:
    print(f"❌ 失败: {resp.text[:1000]}")

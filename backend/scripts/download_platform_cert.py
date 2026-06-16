#!/usr/bin/env python3
"""微信支付平台证书下载脚本
用法: python download_platform_cert.py
前置条件: pip install cryptography requests
"""

import json, os, sys, time
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from base64 import b64decode, b64encode

CERT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'certs'))

def load_config():
    return {
        'mch_id': '1114056630',
        'api_v3_key': os.environ.get('WECHAT_API_V3_KEY', 'asderoiu234nn34234njoij134i9134n'),
        'merchant_key_path': os.path.join(CERT_DIR, 'apiclient_key.pem'),
        'output_path': os.path.join(CERT_DIR, 'wechatpay_platform_cert.pem'),
    }

def build_sign(method, url, body, mch_id, private_key):
    timestamp = str(int(time.time()))
    nonce = os.urandom(16).hex()[:32]
    uri = '/' + '/'.join(url.split('/')[3:])
    sign_str = f"{method}\n{uri}\n{timestamp}\n{nonce}\n{body}\n"
    
    print(f"  [debug] method={method} uri={uri}")
    print(f"  [debug] timestamp={timestamp} nonce={nonce}")
    print(f"  [debug] sign_str=<<<{sign_str}>>>")
    
    signature = b64encode(
        private_key.sign(sign_str.encode(), padding.PKCS1v15(), hashes.SHA256())
    ).decode()
    
    auth = f'WECHATPAY2-SHA256-RSA2048 mchid="{mch_id}",nonce_str="{nonce}",timestamp="{timestamp}",signature="{signature}"'
    print(f"  [debug] auth=<<<{auth[:100]}...>>>")
    return auth

def decrypt_aes_256_gcm(key, ciphertext, nonce, aad):
    key_bytes = key.encode()[:32]
    nonce_bytes = nonce.encode()[:12]
    cipher = Cipher(algorithms.AES(key_bytes), modes.GCM(nonce_bytes))
    decryptor = cipher.decryptor()
    decryptor.authenticate_additional_data(aad.encode())
    return decryptor.update(b64decode(ciphertext)) + decryptor.finalize()

def main():
    cfg = load_config()
    
    # 加载商户私钥
    with open(cfg['merchant_key_path'], 'rb') as f:
        private_key = serialization.load_pem_private_key(f.read(), password=None)
    
    url = 'https://api.mch.weixin.qq.com/v3/certificates'
    auth = build_sign('GET', url, '', cfg['mch_id'], private_key)
    
    resp = requests.get(url, headers={
        'Authorization': auth,
        'Accept': 'application/json',
        'User-Agent': 'CoEvo/0.1',
    })
    
    if resp.status_code != 200:
        print(f"❌ API 请求失败 (HTTP {resp.status_code}): {resp.text}")
        sys.exit(1)
    
    data = resp.json()
    certs = data.get('data', [])
    if not certs:
        print("❌ 响应中没有证书数据")
        sys.exit(1)
    
    # 取第一个有效证书
    cert_info = certs[0]
    encrypt_cert = cert_info['encrypt_certificate']
    
    plain_pem = decrypt_aes_256_gcm(
        cfg['api_v3_key'],
        encrypt_cert['ciphertext'],
        encrypt_cert['nonce'],
        encrypt_cert['associated_data']
    )
    
    os.makedirs(CERT_DIR, exist_ok=True)
    with open(cfg['output_path'], 'wb') as f:
        f.write(plain_pem)
    
    print(f"✅ 平台证书已保存: {cfg['output_path']}")
    print(f"   序列号: {cert_info['serial_no']}")
    print(f"   有效期至: {cert_info['expire_time']}")

if __name__ == '__main__':
    main()

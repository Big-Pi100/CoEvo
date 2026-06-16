from cryptography.hazmat.primitives import serialization

key_path = r"E:\CoEvo\backend\certs\apiclient_key.pem"
with open(key_path, "rb") as f:
    key_data = f.read()

try:
    key = serialization.load_pem_private_key(key_data, password=None)
    print("PKCS#8 (no password): OK")
except Exception as e:
    print(f"No password failed: {e}")
    try:
        key = serialization.load_pem_private_key(key_data, password=b"")
        print("PKCS#8 (empty password): OK")
    except Exception as e2:
        print(f"Empty password failed: {e2}")
        print("First line:", key_data.split(b"\n")[0])

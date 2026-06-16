from cryptography import x509
from cryptography.hazmat.backends import default_backend

with open(r"E:\CoEvo\backend\certs\apiclient_cert.pem", "rb") as f:
    cert = x509.load_pem_x509_certificate(f.read(), default_backend())
print("Serial:", format(cert.serial_number, "X"))

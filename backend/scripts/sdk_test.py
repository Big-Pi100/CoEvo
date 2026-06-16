#!/usr/bin/env python3
"""用微信支付官方 SDK 测试下单 v3"""
import os
from wechatpayv3 import WeChatPay, WeChatPayType

CERT_DIR = r"E:\CoEvo\backend\certs"
KEY_FILE = os.path.join(CERT_DIR, "apiclient_key.pem")

with open(KEY_FILE) as f:
    private_key = f.read()

with open(os.path.join(CERT_DIR, "pub_key.pem")) as f:
    public_key = f.read()

wxpay = WeChatPay(
    WeChatPayType.NATIVE,
    mchid="1114056630",
    private_key=private_key,
    cert_serial_no="7A032EB2A835CC9AD8BAE06C52937ADC21EA1FE9",
    appid="wx4f90b0f2c9f46504",
    apiv3_key="asderoiu234nn34234njoij134i9134n",
    notify_url="https://keyievolution.fun/api/pay/notify",
    public_key_id="PUB_KEY_ID_0111140566302026061500112156001801",
    public_key=public_key,
)

import time
out_trade_no = f"PYTEST_{int(time.time())}"

print(f"=== Native 下单 (out_trade_no={out_trade_no}) ===")
try:
    result = wxpay.pay(
        description="test",
        out_trade_no=out_trade_no,
        amount={"total": 1},
        pay_type=WeChatPayType.NATIVE,
    )
    print(f"Result: {result}")
except Exception as e:
    print(f"Error: {type(e).__name__}: {e}")

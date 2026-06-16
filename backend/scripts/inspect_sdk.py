"""尝试 wechatpayv3 SDK——打印帮助"""
import wechatpayv3
from wechatpayv3 import WeChatPay
import inspect
sig = inspect.signature(WeChatPay.__init__)
print("Parameters:", list(sig.parameters.keys()))
for name, param in sig.parameters.items():
    if name == 'self': continue
    print(f"  {name}: default={param.default}")

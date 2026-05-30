@echo off
type "E:\CoEvo\backend\crates\api_server\src\plan_handler.rs" | ssh -i %USERPROFILE%\.ssh\coevo_key ubuntu@<OLD_VPS_IP> "cat > /tmp/backend/crates/api_server/src/plan_handler.rs"
if %errorlevel% equ 0 (echo OK) else (echo FAILED)

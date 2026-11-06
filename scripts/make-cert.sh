#!/bin/bash
# 生成自签代码签名证书 MoonRiseDev 并装入登录钥匙串（一次性机器配置）。
# TCC 授权绑定 MoonRise.app 的签名身份，跨重建稳定（替代 ad-hoc）。
#
# 用法：
#   bash scripts/make-cert.sh            # 生成证书/私钥并导入钥匙串
#   bash scripts/make-cert.sh --trust    # 应用用户域代码签名信任
#                                        # （系统会弹确认框，需手动点"始终信任"）
# 验证：
#   security find-identity -v -p codesigning | grep MoonRiseDev   # 应显示 1 valid
set -euo pipefail
CERT_DIR="$HOME/.config/moonrise/certs"
mkdir -p "$CERT_DIR"
CERT_PEM="$CERT_DIR/MoonRiseDev.cert.pem"

if [ "${1:-}" = "--trust" ]; then
  [ -f "$CERT_PEM" ] || { echo "❌ 未找到 $CERT_PEM，先不带参数运行一次"; exit 1; }
  # 用户域信任设置：可能弹出系统确认框，点击"始终信任"
  # （若仍报 invalid parameters，用系统域：sudo security add-trusted-cert -d -r trustRoot "$CERT_PEM"）
  security add-trusted-cert -r trustRoot "$CERT_PEM"
  security find-identity -v -p codesigning | grep MoonRiseDev \
    && echo "✅ 信任已生效，重新运行 scripts/install-app.sh 即以稳定签名安装"
  exit 0
fi

CERT_NAME="${CERT_NAME:-MoonRiseDev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✅ 证书 $CERT_NAME 已存在且有效"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 清理旧的同名身份（无效旧证书会让 codesign/find-identity 歧义）
security delete-identity -c MoonRiseDev >/dev/null 2>&1 || true

# 含 codeSigning EKU 的自签证书（缺该扩展 codesign 会拒绝）
cat > "$WORK/ext.cnf" <<CNF
[req]
distinguished_name = dn
[dn]
[ext]
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:TRUE, pathlen:0
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=$CERT_NAME/O=moonrise" \
  -config "$WORK/ext.cnf" -extensions ext \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem"

# PEM 直导（openssl 3.x 的 p12 加密与 security import 不兼容）
security import "$WORK/key.pem" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -T /usr/bin/codesign
security import "$WORK/cert.pem" \
  -k "$HOME/Library/Keychains/login.keychain-db"

# 证书固定保存，供 --trust 与后续审计使用
cp "$WORK/cert.pem" "$CERT_PEM"
echo "✅ 证书/私钥已导入钥匙串，证书副本：$CERT_PEM"
echo "下一步：bash scripts/make-cert.sh --trust"

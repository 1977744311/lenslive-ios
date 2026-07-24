#!/usr/bin/env bash
# 拉取 App 工程真实 SDK 依赖（MWDAT + HaishinKit）并全编译验证。
# 背景：本机直连 GitHub HTTPS 很慢，git 走 gh-proxy.com 镜像 + 本机代理最稳。
# 2026-07-24 晚间网络单连接 >10MB 即断（三通道复现），请在网络正常时段运行本脚本。
set -euo pipefail
cd "$(dirname "$0")/.."

MIRROR="${MIRROR:-https://gh-proxy.com/https://github.com/}"
PROXY="${PROXY:-http://127.0.0.1:7897}"

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.${MIRROR}.insteadOf"
export GIT_CONFIG_VALUE_0="https://github.com/"
export HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY"

[ -d LensLive.xcodeproj ] || xcodegen generate

echo "== 解析依赖 mirror=${MIRROR} =="
xcodebuild -project LensLive.xcodeproj -scmProvider system -resolvePackageDependencies

echo "== 全编译（iOS Simulator）=="
xcodebuild -project LensLive.xcodeproj -scheme LensLive \
  -destination "generic/platform=iOS Simulator" -scmProvider system build \
  | grep -E "error:|warning:.*(Adapter|MWDAT|Haishin)|BUILD SUCCEEDED|BUILD FAILED"

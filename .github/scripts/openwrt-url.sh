#!/bin/sh
# Print the x86/64 download directory of the newest OpenWrt release in a series, e.g. 24.10
base=https://downloads.openwrt.org/releases
ver=$(curl -fsSL "$base/" | grep -oE "$1\.[0-9]+/" | tr -d / | sort -uV | tail -n1)
echo "$base/${ver:-$1-SNAPSHOT}/targets/x86/64"

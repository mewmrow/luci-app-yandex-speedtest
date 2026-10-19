#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Yandex speed test card for Status Overview
LUCI_DESCRIPTION:=Measures download and upload speed to Yandex (Internetometer) from the router
LUCI_DEPENDS:=+curl +rpcd-mod-ucode
LUCI_PKGARCH:=all
LUCI_URL:=https://github.com/mewmrow/luci-app-yandex-speedtest
LUCI_MAINTAINER:=mewmrow

PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

define Package/luci-app-yandex-speedtest/conffiles
/etc/config/yandex-speedtest
endef

define Package/luci-app-yandex-speedtest/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || rm -rf /tmp/yandex-speedtest
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

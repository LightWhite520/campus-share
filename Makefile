include $(TOPDIR)/rules.mk

LUCI_TITLE:=Campus bandwidth sharing manager
LUCI_DEPENDS:=+luci-base +mwan3 +curl +jsonfilter +flock +conntrack
LUCI_PKGARCH:=all
PKG_LICENSE:=MIT
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

define Package/luci-app-campus-share/conffiles
/etc/config/campus_share
endef

define Package/luci-app-campus-share/postinst
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || /usr/libexec/campus-share-setup
endef

include ../../luci.mk

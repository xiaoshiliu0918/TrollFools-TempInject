#!/bin/sh

XCCONFIG_NAME=TrollFools/Version.xcconfig
VERSION=$(awk -F "=" '/VERSION/ {print $2}' $XCCONFIG_NAME | tr -d ' ')
BUILD_NUMBER=$(awk -F "=" '/BUILD_NUMBER/ {print $2}' $XCCONFIG_NAME | tr -d ' ')

mkdir -p packages $THEOS_STAGING_DIR/Payload
cp -rp $THEOS_STAGING_DIR$THEOS_PACKAGE_INSTALL_PREFIX/Applications/TrollFools.app $THEOS_STAGING_DIR/Payload
chmod 0644 $THEOS_STAGING_DIR/Payload/TrollFools.app/Info.plist

# TempInject: bundle the CLI watchdog binary into the .app
if [ -f $THEOS_STAGING_DIR$THEOS_PACKAGE_INSTALL_PREFIX/usr/local/bin/trollfoolscli ]; then
	cp -p $THEOS_STAGING_DIR$THEOS_PACKAGE_INSTALL_PREFIX/usr/local/bin/trollfoolscli $THEOS_STAGING_DIR/Payload/TrollFools.app/trollfoolscli
	chmod 0755 $THEOS_STAGING_DIR/Payload/TrollFools.app/trollfoolscli
fi

cd $THEOS_STAGING_DIR
# 7z a -tzip 石榴注入器.tipa Payload
zip -qr 石榴注入器.tipa Payload
cd -

cp -p $THEOS_STAGING_DIR/石榴注入器.tipa packages

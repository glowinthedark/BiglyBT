#JAVA_HOME=`/usr/libexec/java_home -v 1.8`
set -x

echo 'run mvn clean package first...'

cp uis/target/BiglyBT.jar files
cp uis/target/swt.jar files
cp uis/target/commons-cli.jar files
cp -r uis/target/dll files


jpackage --type dmg \
 -i files \
 -n Bigly2021 \
 --main-class com.biglybt.ui.Main \
 --main-jar BiglyBT.jar \
 --java-options -XstartOnFirstThread \
 --mac-package-name Bigly2021-lk \
 --icon ../app.icns \
 --verbose
#   -BjvmOptions=-Xmx1g \
#   -BjvmOptions=-Xms512m \
#   -BjvmOptions=-XstartOnFirstThread \
#   -BsystemWide=true \
#   -srcdir . \
#  -srcfiles "BiglyBT.jar swt.jar commons-cli.jar dll/libOSXAccess_10.5.jnilib" \
#     -Bmainjar=BiglyBT \
#  -outdir release-dist \
#  -outfile ${APP_DIR_NAME} \
#  -appclass  \
#  -name "Bigly21" \
#  -title "Bigly21" \
#  -nosign -v
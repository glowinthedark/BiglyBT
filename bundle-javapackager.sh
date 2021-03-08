#JAVA_HOME=`/usr/libexec/java_home -v 1.8`
set -x

APP_DIR_NAME=Biglylk21.app
#-Bruntime=${JAVA_HOME} \

#  -classpath BiglyBT.jar:swt.jar:commons-cli.jar:dll/libOSXAccess_10.5.jnilib \


javapackager  -deploy -native \
   -BjvmOptions=-Xmx1g \
   -BjvmOptions=-Xms512m \
   -BjvmOptions=-XstartOnFirstThread \
   -BsystemWide=true \
   -srcdir uis/target \
  -srcfiles "BiglyBT.jar swt.jar commons-cli.jar dll/libOSXAccess_10.5.jnilib" \
     -Bmainjar=BiglyBT \
  -outdir release-dist \
  -outfile ${APP_DIR_NAME} \
  -appclass com.biglybt.ui.Main \
  -name "Bigly21" \
  -title "Bigly21" \
  -nosign -v
#!/bin/bash

if [ "X$1" != "X" ] ; then
        DEV=$1
else
        echo "Usage: copy_all [emulator|topaz]"
        exit
fi
echo "Device = $DEV"
DEVICE=`novaterm -l | grep $DEV | awk '{print $2}'`

if [ "X$DEVICE" == "X" ] ; then
        echo "Device '$DEV' is not connected!'"
        exit
fi

function copy_file {
        base=`basename $1`
        # Copy the file to the device
        CPY_CMD="novacom -d $DEVICE put file://$DEST/$1 < $SOURCE/$1"
        # echo "Copying" $base
        eval $CPY_CMD
}

# Copy a folder to the device
function copy_folder {
        cd $SOURCE

        # Make all the required directories
        DIR_LIST=`find -type d | grep -v svn`
        for CUR_DIR in $DIR_LIST ; do
                novacom -d $DEVICE run "file:////bin/mkdir -p $DEST/$CUR_DIR"
        done

        # Copy all the files
        FILE_LIST=`find -type f | grep -v svn | grep -v .project`
        for CUR_FILE in $FILE_LIST ; do
                copy_file $CUR_FILE ;
        done
}

#########################################################
# Stop LunaSysMgr
#########################################################
echo "Stopping LunaSysMgr ..."
novacom -d $DEVICE run "file:///sbin/stop LunaSysMgr"


#########################################################
# Copy the FirstUse app to the phone
#########################################################
echo "Copying FirstUse app to $DEV ..."
SOURCE="/home/YOURNAMEHERE/workspace/com.palm.app.firstuse/trunk"
DEST="/usr/palm/applications/com.palm.app.firstuse"
copy_folder ;




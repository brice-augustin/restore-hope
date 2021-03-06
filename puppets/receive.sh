#!/bin/bash

function cleanup
{
  # Unmount fs (for commands that require it to be mounted)
  #if [ $cmd == "exec" -o $cmd == "send" ]
  #then
  #  if [ $mounted -eq 1 ]
  #  then
  #     echo "Unmounting $RH_MOUNTDIR"
  #
  #
  #     umount --recursive $RH_MOUNTDIR
  #   fi
  # fi

  # umount RH_DIR if mounted
  if [ ! -z "$prefix" ]
  then
    mount | grep $RH_MOUNTDIR > /dev/null 2>&1
    if [ $? -eq 0 ]
    then
      echo "Unmounting $RH_MOUNTDIR"

      # --recursive (on older systems?)
      # A éviter car impossible de rebooter après (arrêt sur Reached Target Shutdown)
      # umount --lazy $RH_MOUNTDIR

      # https://unix.stackexchange.com/questions/61885/how-to-unmount-a-formerly-chrootd-filesystem
      umount $RH_MOUNTDIR/dev/
      umount $RH_MOUNTDIR/proc/
      umount $RH_MOUNTDIR/sys/
      umount $RH_MOUNTDIR
    fi
  fi

  if [ -f $RH_DIR/current_cmd ]
  then
    pid=$(cat $RH_DIR/current_cmd)
    # remove file only if it is mine
    if [ $pid -eq $$ ]
    then
      rm $RH_DIR/current_cmd
    fi
  fi
}

####
# Send report to the master
####
function report
{
  if [ ! -f $RH_DIR/current_cmd ]
  then
    return
  fi

  pid=$(cat $RH_DIR/current_cmd)

  # A "cancel" command was run after this command. Omit the report.
  if [ $pid -ne $$ ]
  then
    return
  fi

  if [ $rh_cmd_res -eq 0 ]
  then
    echo RHOK
  else
    echo RHNOK
  fi

  if [ -n "$SSH_CLIENT" ]
  then
    masterip=$(echo $SSH_CLIENT | awk '{print $1}')
    netif=$(ip route | grep default | awk '{print $5}')
    netip=$(ip -o -4 a list $netif | awk '{print $4}' | cut -d '/' -f1)
    # Attention -q peut masquer des erreurs
    # Exemple "ssh_exchange_identification: read: connection reset by peer"
    # quand sshd est submergé de requêtes et en refuse certaines
    # (synchro des puppets après un udpcast)
    scp -q $RH_DIR/nohup.log $masterip:$RH_DIR/puppets/$netip.nohup
    # 2> /dev/null
  else
    cp $RH_DIR/nohup.log $RH_DIR/puppets/local.nohup
  fi
}

# Centralize that!
RH_MOUNTDIR=/mnt/rh
RH_DIR="/root/rh2"
RESTORE2_PATH="/usr/local/sbin/restore2.sh"
RH_CONF="/etc/restore/base_restore.conf"

http_proxy=${http_proxy:-http://proxy.iutcv.fr:3128}
https_proxy=${https_proxy:-$http_proxy}
ftp_proxy=${ftp_proxy:-$http_proxy}

if [ $# -lt 1 ]
then
  echo "$0 send system dstpath [localfile]"
  echo "$0 exec system cmd"
  echo "$0 cancel"
  echo "$0 restore system"
  echo "$0 save system"
  exit
fi

echo Remote command: "$@"

cmd=$1
system=$2

if [ $system != "rh" ]
then
  partition=$(grep "^$system:" $RH_CONF | cut -d ':' -f 3)
else
  partition="rh"
fi

shift 2

####
# Cancel previous command
####
if [ $cmd == "cancel" ]
then
  if [ ! -f $RH_DIR/current_cmd ]
  then
    echo "Nothing to cancel"
    rh_cmd_res=0
    report
    exit
  fi

  current_cmd=$(cat $RH_DIR/current_cmd)

  # The cancelled command will know it has been cancelled
  echo $$ > $RH_DIR/current_cmd

  echo RHCANCEL

  # kill children (eg partclone, udp-receiver, etc)
  pkill -P $current_cmd
  # kill script
  pkill $current_cmd

  # always succeed?
  rh_cmd_res=0

  report

  cleanup

  #echo -e "${RED}You have to umount partitions manually${NC}"

  #kill -SIGHUP 798
  #pkill -P 798 then pkill 798 => si un autre child est lancé entre les deux ???
  #ps -ax -o pid=,ppid=,command=

  exit
fi

# Save the PID of the currently running script
# (used by "cancel" command)
echo $$ > $RH_DIR/current_cmd

####
# Automatically mount system partition
####
if [ $cmd == "exec" -o $cmd == "send" ]
then
  if [ $partition == "rh" ]
  then
    # No need to mount, use root filesystem
    prefix=""
  else
    prefix=$RH_MOUNTDIR
    if [ ! -d  $RH_MOUNTDIR ]
    then
      mkdir $RH_MOUNTDIR
    fi

    echo "Mounting $partition on $RH_MOUNTDIR"
    mount $partition $RH_MOUNTDIR

    if [ $? -ne 0 ]
    then
      echo "Cannot mount $partition on $RH_MOUNTDIR"

      rh_cmd_res=1

      report

      exit
    fi
  fi
fi

ischroot
isc=$?
# exec command, must chroot
if [ $cmd == "exec" -a $isc -ne 0 ]
then
  # exec on RH system
  if [ $partition == "rh" ]
  then
    all=$@
    /bin/bash -c "$all"

    # Warning : if one of the commands inside the pipeline fails
    # (except the last), bash returns 0
    rh_cmd_res=$?
  # exec on other system: need to chroot
  else
    line=$(grep ":$partition:" $RH_CONF)
    type=$(echo $line | cut -d ':' -f 5)

    if [ $type != "ext4" ]
    then
      echo "Exec command works only on Linux systems (Ext4)"
      cleanup
      rh_cmd_res=1
      report
      exit
    fi

    # http://shallowsky.com/blog/tags/chroot/
    mount --bind /dev $RH_MOUNTDIR/dev/
    mount --bind /proc $RH_MOUNTDIR/proc/
    mount --bind /sys $RH_MOUNTDIR/sys/

    tmpfile=$(mktemp)
    cp $RH_MOUNTDIR/etc/resolv.conf $tmpfile
    cp /etc/resolv.conf $RH_MOUNTDIR/etc/resolv.conf

    # http_proxy was setup earlier
    chroot $RH_MOUNTDIR /bin/bash -c "$@"
    # chroot returns the exit status of the command

    rh_cmd_res=$?

    cp $tmpfile $RH_MOUNTDIR/etc/resolv.conf
  fi

  # XXX test&debug, remove
  #/bin/bash -c "$@"
elif [ $cmd == "restore" ]
then
  echo "restore"
  # Invoquer le script de restauration de manière non-interactive.
  $RESTORE2_PATH $system

  rh_cmd_res=$?
elif [ $cmd == "save" ]
then
  echo save arguments : "$@"

  line=$(grep ":$partition:" $RH_CONF)

  if [ $? -ne 0 ]
  then
    echo "$partition does not exist"
    cleanup
    rh_cmd_res=1
    report
    exit
  fi
  image=$(echo $line | cut -d ':' -f 4)
  type=$(echo $line | cut -d ':' -f 5)

  set -o pipefail

  partclone.$type -c -s $partition | gzip -c > $image

  rh_cmd_res=$?
  set +o pipefail
elif [ $cmd == "send" ]
then
  dstpath=$1
  localfile=$2

  # send mode => not in chroot
  fullpath=$prefix$dstpath

  if [ ! -d $fullpath ]
  then
    echo "Destination $fullpath must be a directory and must exist"
    # XXX frequency
    beep
    rh_cmd_res=1
    report
    cleanup
    exit
  fi

  if [ -z $localfile ]
  then
    echo "udp-receiver"
    # XXX interface on local machine : lo

    netif=$(ip route | grep default | awk '{print $5}')

    udp-receiver --interface $netif --nokbd | tar xC $fullpath
    rh_cmd_res=$?

    # Retard aléatoire pour éviter synchro parfaite des puppets,
    # ce qui pousse sshd à refuser des connexions
    sleep $((RANDOM % 5)).$((RANDOM % 100))
  else
    echo "local cp"
    cp -r $localfile $fullpath
    rh_cmd_res=$?
  fi
fi

report

cleanup

#!/bin/bash

#set -x

usage() {
  echo "Usage: $0 [options] <script.sh> [listOfMachines.txt ...]" 1>&2
  echo "" 1>&2
  echo "Options:" 1>&2
  echo "  -U, --user     Use a user other than root" 1>&2
  echo "  -q, --quick    Quick mode, don't ask questions" 1>&2
  echo "  -s, --ssh      Force use of SSH copy mode" 1>&2
  echo "  -l, --logdir   Directory to write log files to" 1>&2
  echo "  -u, --url      Base of URL to get scripts from" 1>&2
  echo "  -w, --webdir   Base of directory to copy scripts, should match URL" 1>&2
  echo "  -c, --counter  File to use as a counter" 1>&2
  echo "  -f, --localfirst Do local machine first" 1>&2
  echo "  -L, --locallast  Do local machine last" 1>&2
  echo "" 1>&2
  echo "If url and webdir are specified, wget will be used for copying scripts," 1>&2
  echo "otherwise SSH will be used to copy." 1>&2
  echo "" 1>&2
  echo "Options that may be stored set in ~/.domany.conf:" 1>&2
  echo "  USER, QUICK, FORCESSH, LOGDIR, URL, WEBDIR, COUNTER, LOCAL" 1>&2
  exit 1
}

pingMachines () {
  echo "About to ping $(cat $workMachinesFile | wc -l) machine(s), please wait."

  # fping the whole list to show the ones that are up/down when we start.
  perl -p -e 's/(^|\s+)[^\s]+@/$1/' $workMachinesFile | fping  > $fpingMachinesFile
  err=$?

  cat $fpingMachinesFile | grep 'is alive$' | cut -f 1 -d ' ' | sort > $fpingMachinesFile.up
  cat $fpingMachinesFile | grep 'is unreachable$' | cut -f 1 -d ' ' | sort > $fpingMachinesFile.down


  if [ -s "$fpingMachinesFile.up" ]; then
    echo
    echo "Machines up:"
    cat $fpingMachinesFile.up
  fi

  if [ -s "$fpingMachinesFile.down" ]; then
    echo
    echo "Machines down:"
    cat $fpingMachinesFile.down


    downCount=$(wc -l $fpingMachinesFile.down | cut -f 1 -d ' ')
    if [ $err -ne 0 ]; then
      if [ ! "$QUICK" ]; then
        echo
        read -p "$downCount machine(s) down, do you want to exclude them? [Y/n/r/^c] " answer
        if [ $? -ne 0 ]; then
          exit 1
        fi

        if [ "$answer" = "y" -o "$answer" = "Y" -o -z "$answer" ]; then
          cat $fpingMachinesFile.up > $workMachinesFile
        fi

        if [ "$answer" = "r" -o "$ansrwer" = "R" ]; then
          pingMachines
        fi
      else
        echo
        echo "Excluding $downCount down machine(s)."
        cat $fpingMachinesFile.up > $workMachinesFile
      fi
    fi
  fi
}

#set -x
TEMP=$(getopt --options U:qsl:u:w:c:fL --long user:quick,localfirst,locallast,ssh,logdir:url:webdir:counter: -n $0 -- "$@")

if [ $? != 0 ]; then
  usage
fi

eval set -- "$TEMP"

URL=
WEBDIR=
QUICK=
LOGDIR=./log
FORCESSH=
USER=root
COUNTER=
LOCAL=

test -e ~/.domany.conf && source ~/.domany.conf

while true ; do
  case "$1" in
    -U|--user)
      USER=$2
      shift
      ;;
    -q|--quick)
      QUICK=1
      shift
      ;;
    -s|--ssh)
      FORCESSH=1
      shift
      ;;
    -u|--url)
      URL=$2
      shift 2
      ;;
    -w|--webdir)
      WEBDIR=$2
      shift 2
      ;;
    -c|--counter)
      COUNTER=$2
      shift 2
      ;;
    -f|--localfirst)
      LOCAL=first
      shift
      ;;
    -L|--locallast)
      LOCAL=last
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done

if [ "$FORCESSH" ]; then
  URL=
  WEBDIR=
fi

if [ "$WEBDIR" -o "$URL" ]; then
  if [ ! "$WEBDIR" -o ! "$URL" ]; then
    echo "ERROR: You must specify webdir with url" 1>&2
    usage
  fi
fi

SCRIPTFILE=$1
shift

if [ -z "$SCRIPTFILE" ]; then
  usage
fi

scriptBaseName=$(basename $SCRIPTFILE)

workDir=$(mktemp -d /tmp/$scriptBaseName-XXXXXX)

workMachinesFile=$workDir/machines.txt
doneMachinesFile=$workDir/doneMachines.txt
downMachinesFile=$workDir/downMachines.txt
errorMachinesFile=$workDir/errorMachines.txt
fpingMachinesFile=$workDir/fpingMachines.txt
doneLogFile=$workDir/done.txt

touch $doneMachinesFile
touch $downMachinesFile
touch $errorMachinesFile
touch ${workMachinesFile}.sort


cat > $workMachinesFile.edit <<TEMPLATEEOF
# Edit this file to change the hosts that the script will run on.
# Anything after #'s is ignored.
# Script: $SCRIPTFILE
TEMPLATEEOF

if [ "$*" ]; then
  cat $* > ${workMachinesFile}.sort
fi

sort -n ${workMachinesFile}.sort | uniq >> $workMachinesFile.edit

sensible-editor $workMachinesFile.edit

cat $workMachinesFile.edit | sed -e 's/\s*\#.*//' | egrep -v '^[[:space:]]*$' > $workMachinesFile

pingMachines

if [ ! -s "$workMachinesFile" ]; then
  echo "Nothing to do."
  exit 0
fi

if [ "$LOCAL" ]; then
  echo "LOCAL: $LOCAL"
  if grep -iq $(hostname -f) $workMachinesFile ; then
    touch $workMachinesFile.local

    if [ "$LOCAL" = "first" ]; then
      hostname -f >> $workMachinesFile.local
    fi

    grep -v $(hostname -f) $workMachinesFile >> $workMachinesFile.local

    if [ "$LOCAL" = "last" ]; then
      hostname -f >> $workMachinesFile.local
    fi
  fi

  cp $workMachinesFile.local $workMachinesFile
fi

echo
if [ "$COUNTER" ]; then
  echo "Locking counter..."
  lockfile -1 -r -1  ${COUNTER}.lock
  if [ $? -ne 0 ]; then
    echo "ERROR: Unable to lock $COUNTER" 1>&2
    exit 1
  fi

  set -e
  touch ${COUNTER}
  counterVal=$(cat $COUNTER);
  counterVal=$(($counterVal + 1))
  echo $counterVal > $COUNTER
  rm -f ${COUNTER}.lock

  LOGDIR=$LOGDIR/${counterVal}_$(date +%F-%T)_${scriptBaseName}
  mkdir -p $LOGDIR
  set +e

  echo "Beginning launch loop, counter=$counterVal."
else
  echo "Beginning launch loop."
fi



startTime=$(date +"%F %T %Z")

if [ "$URL" ]; then
  tempScriptFileBaseName=$(basename $(mktemp -u -t $scriptBaseName-XXXXXX));
  tempScriptFile=/tmp/$tempScriptFileBaseName
  tempWebScriptFile=$WEBDIR/$tempScriptFileBaseName

  URL=$URL/$tempScriptFileBaseName

  rsync $SCRIPTFILE $tempWebScriptFile
fi

cat $workMachinesFile

for machine in $(cat $workMachinesFile); do
  user=${machine%@*}
  if [[ -n "$user" ]] || [[ "$user" = "$machine" ]]; then
    user=$USER
  fi
  echo "User: $user  Machine: $machine"
  machine=${machine#*@}
  if [ "$counterVal" ]; then
    scriptLogFile=$LOGDIR/$(date +%F-%T)_${machine}.log
  else
    scriptLogFile=$LOGDIR/$(date +%F-%T)_${scriptBaseName}_${machine}.log
  fi

  if fping -q $machine; then
    if [ ! "$QUICK" ]; then
      read -p "Press enter to do $machine, ! to do all, ^C to stop: " line || exit 1
      if [[ "$line" = "!" ]]; then
        QUICK=yes
      fi
    else
      echo "Doing $user@$machine."
    fi

    launchScript=$(mktemp $workDir/launchScript-XXXXXX);
    if [ "$URL" ]; then
      cat > $launchScript <<LAUNCHSCRIPTEOF
#!/bin/bash
ssh -o "StrictHostKeyChecking no" -t $user@$machine "wget $URL -O $tempScriptFile && chmod +x $tempScriptFile && nice $tempScriptFile; err=\\\$?; rm $tempScriptFile; exit \\\$err"
err=\$?

if [ \$err -ne 0 ]; then
  echo "$machine # WWW Script returned error code: \$err" >> $errorMachinesFile
else
  echo $machine >> $doneMachinesFile;
fi

echo -en "\\033]0;Done $machine\\007\a"
read -p "Done, press enter."
LAUNCHSCRIPTEOF
    else
      tempScriptFile=$(mktemp -u -t $scriptBaseName-XXXXXX);
      cat > $launchScript <<LAUNCHSCRIPTEOF
#!/bin/bash
echo Copying $SCRIPTFILE to $user@$machine:$tempScriptFile
scp $SCRIPTFILE $user@$machine:$tempScriptFile

if [ \$? -ne 0 ]; then
  echo "$machine # Unable to copy script" >> $errorMachinesFile
else
  echo "Running $tempScriptFile on $machine"
  ssh -o "StrictHostKeyChecking no" -t $user@$machine "chmod +x $tempScriptFile; nice $tempScriptFile; err=\\\$?; rm $tempScriptFile; exit \\\$err"

  err=\$?

  if [ \$err -ne 0 ]; then
    echo "$machine - Script returned error code: \$err" >> $errorMachinesFile
  else
    echo $machine >> $doneMachinesFile;
  fi
fi

echo -en "\\033]0;Done $machine\\007\a"
read -p "Done, press enter."
LAUNCHSCRIPTEOF
    fi

    chmod +x $launchScript

    #echo "Doing $machine..."
    gnome-terminal \
      --sm-disable \
      --disable-factory \
      --title "Doing $machine" \
      --execute script -f $scriptLogFile -c $launchScript &
    sleep 1
  else
    echo "Skipping machine $machine since it isn't answering pings."
    echo $machine >> $downMachinesFile
  fi
done


echo
echo "Done launching commands, waiting for completion..."
sleep 1

wait

endTime=$(date +"%F %T %Z")

if [ "$counterVal" ]; then
  echo "Counter: $counterVal" >> $doneLogFile
fi
echo "Script: $scriptBaseName" >> $doneLogFile
echo "Start: $startTime" >> $doneLogFile
echo "End: $endTime" >> $doneLogFile

if [ -s "$doneMachinesFile" ]; then
  echo >> $doneLogFile
  echo "The following machines were done successfully (maybe):" >> $doneLogFile
  sort -n < $doneMachinesFile >> $doneLogFile
fi

if [ -s "$errorMachinesFile" ]; then
  echo >> $doneLogFile
  echo "The following machines had errors:" >> $doneLogFile
  sort -n < $errorMachinesFile >> $doneLogFile
fi

if [ -s "$downMachinesFile" ]; then
  echo >> $doneLogFile
  echo "The following machines were skipped because they didn't answer pings:" >> $doneLogFile
  sort -n < $downMachinesFile >> $doneLogFile
fi

echo
cat $doneLogFile

if [ "$counterVal" ]; then
  mv $doneLogFile $LOGDIR/done.log
else
  mv $doneLogFile $LOGDIR/$(date +%F-%T)_${scriptBaseName}_done.log
fi

if [ "$tempWebScriptFile" ]; then
  if echo $tempWebScriptFile | grep -q :; then
    tempWebHost=$(echo $tempWebScriptFile | cut -f 1 -d cut)
    tempWebFile=$(echo $tempWebScriptFile | cut -f 2- -d cut)
    ssh $tempWebHost rm $tempWebFile
  else
    rm $tempWebScriptFile
  fi
fi

rm -rf $workDir

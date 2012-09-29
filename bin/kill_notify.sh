#!/bin/sh
if [ "$#" -ne 1 ]; then
  echo "Kill the pid of the process and send email about the detail."
  echo "Usage: $0 <pid>" >&2
  exit 1
fi

pid=$1
p_args=`ps -p $pid -o args=`
ppid=`ps -p $pid -o ppid=`
service=`ps -p $ppid -o args= | cut -d" " -f2`
hostname=`hostname -s`
#TMPDIR="/tmp"
#FILE="$TMPDIR/jstack.$pid.$(date +%H%M%S.%N)"
#stack=`jstack -l $pid > $FILE 2>&1 && cat $FILE`

# Kill the process
kill -9 $pid

## Poor man's notification is following

## template message
BODY=$( cat <<EOF
Process $pid got out of memory error on $hostname. It has been killed and is (hopefully) restarted
\n
PID: $pid\n
HOSTNAME: $hostname\n
SERVICE: $service\n
CMDLINE: $p_args\n
EOF
)

SUBJECT="FATAL - OOM on $hostname for service $service"

EMAIL_TO="production-notifications@foo.com"
echo -e $BODY | mail -s "$SUBJECT" $EMAIL_TO
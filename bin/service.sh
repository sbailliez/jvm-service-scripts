#!/bin/bash
#
#  Script that is hopefully useful to run some java applications in a fairly generic way given a simple directory layout.
#
# The layout is typically
#
#  project
#       bin                   - directory typically containing this script 
#       config                - the general location for all configuration
#          service.conf       - (optional) env variables set for all configurations
#            config_a         - name of configuration to pass to the service
#               service.conf  - (optional) env variables set for all configurations
#               jvm.config    - (optional) list of jvm properties (can be on several lines)
#       log                   - where logs are to be written to
#       lib                   - directory where jars are collected to run
#         agent               - usually newrelic.jar is expected to be packaged into this directory as 'newrelic.jar'
#         endorsed            - will place this directory as endorsed dir to run the jvm
#       dist                  - this is where the jar of the service will be built
#         instrumented        - where the cobertura instrumented jar resides along with the reference file .ser file
#
#
#   service could be invoked by:
#
#   bin/service.sh start -c config_a
# 
#  Possible commands include:
#  run        - will block in the console, more suitable for development purposes
#  start/stop - adequate for sysinit style
#  supervise  - ideal for daemontools
#  check      - helpful to check settings
#
# if nothing specified via JAVA_CLASSNAME in service.conf, this will default to this class
DEFAULT_JAVA_CLASSNAME="com.foo.service.Service"

usage()
{
    echo "Usage: $0 {run|start|stop|restart|check|supervise} [ -c CONFIG_NAME ] "
    exit 1
}

running()
{
    [ -f $1 ] || return 1
    PID=$(cat $1)
    ps -p $PID >/dev/null 2>/dev/null || return 1
    return 0
}

source_config()
{
    local config_file="$1/service.conf"
    [ -e "$config_file" ] || return
    echo "Sourcing $config_file"
    . "$config_file"
}

# we want reproducible classpath on machines, so sort the jars alphabetically
find_jar() {
    if [ "`uname`" == "Darwin" ] ; then
        echo "`find $1 -type f -name '*.jar' -print -depth 1 | sort`"
    else
        echo "`find $1 -maxdepth 1 -type f -name '*.jar' -print | sort`"
    fi
}

ACTION=$1
shift

CONFIG=dev
while getopts "c:h" o; do
 case "$o" in
    c)  CONFIG="$OPTARG";;
    h)  usage;;
    \?)  usage;;
 esac
done

# Reset $@
shift `echo $OPTIND-1 | bc`
echo "Running $ACTION with configuration $CONFIG"

# Use service root if provided otherwise assume it is a bin
if [ -z "$SERVICE_ROOT" ] ; then
    cd `dirname $0`/..
    SERVICE_ROOT=`pwd`
fi
cd $SERVICE_ROOT

# Just in case try to go down until you have a config directory
# not great as it can be infinite loop. Should assume the script cannot be more than 2 levels deep
while [ ! -d $SERVICE_ROOT/config ]; do
    cd `dirname $0`/..
    SERVICE_ROOT=`pwd`  
done
echo "Using SERVICE_ROOT as $SERVICE_ROOT"

BASE_CONFIG_DIR="${SERVICE_ROOT}/config"
CONFIG_DIR="${SERVICE_ROOT}/config/$CONFIG"
if [ ! -d $CONFIG_DIR ] ; then
    echo "Invalid configuration $CONFIG. Directory $CONFIG_DIR does not exist."
    exit 1
fi


# add config directory first in classpath
CLASSPATH="$CLASSPATH":"$CONFIG_DIR"

[ -d $SERVICE_ROOT/lib/endorsed ] && JAVA_OPTS="$JAVA_OPTS -Djava.endorsed.dirs=$SERVICE_ROOT/lib/endorsed" || :

if [ ! -z "$SERVICE_INSTRUMENTED" -a -d $SERVICE_ROOT/dist/instrumented  ] ; then
    echo "Using instrumented distribution..."
    for j in $(find_jar "$SERVICE_ROOT/dist/instrumented") ; do
      CLASSPATH="$CLASSPATH":$j
    done
    # Copy cobertura reference file into working directory
    if [ -f $SERVICE_ROOT/dist/instrumented/cobertura.ser ] ; then
		cp -f $SERVICE_ROOT/dist/instrumented/cobertura.ser $SERVICE_ROOT
	fi
fi

if [ -d $SERVICE_ROOT/dist ] ; then
    for j in $(find_jar "$SERVICE_ROOT/dist") ; do
      CLASSPATH="$CLASSPATH":$j
    done
fi

if [ -d $SERVICE_ROOT/lib ] ; then
    for j in $(find_jar "$SERVICE_ROOT/lib") ; do
      CLASSPATH="$CLASSPATH":$j
    done
fi

# Iterate over all directories in config to load service.conf in order.
dir=$BASE_CONFIG_DIR
source_config $dir
for i in `echo $CONFIG | sed 's/\// /g'` ; do
    dir="${dir}/${i}"
    source_config $dir
done



# create log directory if not already done
[ -z "$SERVICE_LOG" ] && SERVICE_LOG="$SERVICE_ROOT/log" || :
[ ! -d $SERVICE_LOG ] && mkdir -p $SERVICE_LOG || :


# Load some global settings we may want to assign to jvm such as encoding, default timeout, etc..
[ -z "$SERVICE_SYSTEM_JVM_CONF" ] && SERVICE_SYSTEM_JVM_CONF="/opt/services/java/jvm.conf" || :
if [ -f "$SERVICE_SYSTEM_JVM_CONF" ] && [ -r "$SERVICE_SYSTEM_JVM_CONF" ]
then
    OPTS=`cat $SERVICE_SYSTEM_JVM_CONF | grep -v "^[[:space:]]*#" | tr "\n" " "`
    JAVA_OPTS="$OPTS $JAVA_OPTS"
fi

#
# jvm parameter which would be configuration specific (typically memory in prod, gc settings, ..) vs dev
#
[ -z "$JVM_CONF" ] && JVM_CONF="${CONFIG_DIR}/jvm.conf" || :
if [ -f "$JVM_CONF" ] && [ -r "$JVM_CONF" ]
then
    OPTS=`cat $JVM_CONF | grep -v "^[[:space:]]*#" | tr "\n" " "`
    JAVA_OPTS="$OPTS $JAVA_OPTS"
fi

# log4j support
if [ -f "$LOG4J_FILE"  ] ; then
    JAVA_OPTS="$JAVA_OPTS -Dlog4j.debug=true -Dlog4j.configuration=file://$LOG4J_FILE"
fi

# if JVM_DEBUG is set, we want to run in debug mode
if [ ! -z "$JVM_DEBUG" ] ; then
    [ -z "$JVM_DEBUG_SUSPEND" ] && JVM_DEBUG_SUSPEND="n" || :
    [ -z "$JVM_DEBUG_ADDRESS" ] && JVM_DEBUG_ADDRESS="5005" || :
    JAVA_OPTS="$JAVA_OPTS -Xdebug -Xrunjdwp:transport=dt_socket,server=y,suspend=$JVM_DEBUG_SUSPEND,address=$JVM_DEBUG_ADDRESS"
fi

# if YOURKIT_HOME is set, assume we want to run it and assume we do so only for linux-x86-64
if [ ! -z "$YOURKIT_HOME" -a -d "$YOURKIT_HOME" ] ; then
    if [ -z "$YOURKIT_OPTIONS" ] ; then
        [ -z "$YOURKIT_SNAPSHOT_DIR" ] && YOURKIT_SNAPSHOT_DIR="/tmp" || :
        [ -z "$YOURKIT_PORT" ] && YOURKIT_PORT="10001" || :
        YOURKIT_OPTIONS="port=$YOURKIT_PORT,dir=$YOURKIT_SNAPSHOT_DIR"
    fi
    JAVA_OPTS="$JAVA_OPTS -agentpath:$YOURKIT_HOME/bin/linux-x86-64/libyjpagent.so=$YOURKIT_OPTIONS"
fi


## newrelic support if present
if [ -f $SERVICE_ROOT/lib/agent/newrelic.jar -a ! -z "$NEWRELIC_ENVIRONMENT" ] ; then
  JAVA_OPTS="$JAVA_OPTS -javaagent:$SERVICE_ROOT/lib/agent/newrelic.jar"
  JAVA_OPTS="$JAVA_OPTS -Dnewrelic.config.file=$BASE_CONFIG_DIR/newrelic.yml"
  JAVA_OPTS="$JAVA_OPTS -Dnewrelic.logfile=$SERVICE_LOG/newrelic_agent.log"
  JAVA_OPTS="$JAVA_OPTS -Dnewrelic.environment=$NEWRELIC_ENVIRONMENT"
fi

# if JAVA is not defined but we have JAVA_HOME
if [ "$JAVA" = "" -a "$JAVA_HOME" != "" ]
then
    [ -x $JAVA_HOME/bin/jre -a ! -d $JAVA_HOME/bin/jre ] && JAVA=$JAVA_HOME/bin/jre
    [ -x $JAVA_HOME/bin/java -a ! -d $JAVA_HOME/bin/java ] && JAVA=$JAVA_HOME/bin/java
fi
# if java is still not defined then look it up from path
[ "$JAVA" = "" ] && JAVA=`which java` || :

# Show the version when starting for confirmation
JAVA_OPTS="$JAVA_OPTS -showversion"


[ -z "$SERVICE_PID" ] && SERVICE_PID="$SERVICE_LOG/service.pid" || :

# Set java classname to default to the most obvious
[ -z "$JAVA_CLASSNAME" ] && JAVA_CLASSNAME="$DEFAULT_JAVA_CLASSNAME" || :

# if we did not specify a specific file, look for the default one in the config dir that was given
[ -z "$SERVICE_CONFIG_FILE" -a -r "$CONFIG_DIR/config.yml" ] && SERVICE_CONFIG_FILE="$CONFIG_DIR/config.yml" || :

# Set system properties to startup the service
[ ! -z "$SERVICE_PORT" ] && JAVA_OPTS="$JAVA_OPTS -Dsvc.http.port=$SERVICE_PORT" || :
[ ! -z "$SERVICE_HOST" ] && JAVA_OPTS="$JAVA_OPTS -Dsvc.http.host=$SERVICE_HOST" || :
[ ! -z "$SERVICE_NAME" ] && JAVA_OPTS="$JAVA_OPTS -Dsvc.service.name=$SERVICE_NAME" || :
[ ! -z "$SERVICE_CONFIG_FILE" ] && JAVA_OPTS="$JAVA_OPTS -Dsvc.config.file=file:$SERVICE_CONFIG_FILE" || :

# for compatibility we need to pass at least one parameter as an argument
[ ! -z "$SERVICE_CONFIG_FILE" -a -z "$JAVA_ARGS" ] && JAVA_ARGS="-config file:$SERVICE_CONFIG_FILE" || :

case "$ACTION" in
  run)
        if [ -z "$JAVA_CLASSNAME" ]
        then
            echo "Missing JAVA_CLASSNAME"
            exit 1
        fi
        RUN_ARGS="$JAVA_OPTS -Duser.dir=$SERVICE_ROOT -cp $CLASSPATH $JAVA_CLASSNAME $JAVA_ARGS"
        RUN_CMD="$JAVA $RUN_ARGS"
        echo $RUN_CMD
        $RUN_CMD
        ;;
  start)
        echo "Starting Service..."
        if [ -f $SERVICE_PID ]
        then
            if running $SERVICE_PID
            then
                echo "Service already running with PID $SERVICE_PID"
                exit 1
            else
                # dead pid file - remove
                rm -f $SERVICE_PID
            fi
        fi
        if [ -z "$JAVA_CLASSNAME" ]
        then
            echo "Missing JAVA_CLASSNAME"
            exit 1
        fi
        RUN_ARGS="$JAVA_OPTS -Duser.dir=$SERVICE_ROOT -cp $CLASSPATH $JAVA_CLASSNAME $JAVA_ARGS"
        RUN_CMD="$JAVA $RUN_ARGS"
        # echo $RUN_CMD >> $SERVICE_LOG/service.log 2>&1
        nohup $RUN_CMD >> $SERVICE_LOG/service.log 2>&1 &
        PID=$!
        echo $PID > $SERVICE_PID
        ;;
  stop)
        echo "Stopping Service..."
        PID=`cat $SERVICE_PID 2>/dev/null`
        TIMEOUT=30
        while running $SERVICE_PID && [ $TIMEOUT -gt 0 ]
        do
            kill $PID 2>/dev/null
            sleep 1
            TIMEOUT=$(( $TIMEOUT - 1 ))
        done

        [ $TIMEOUT -gt 0 ] || kill -9 $PID 2>/dev/null

        rm -f $SERVICE_PID
        echo OK
        ;;

  restart)
        SERVICE_SH=$0
        if [ ! -f $SERVICE_SH ]; then
            echo "$SERVICE_SH does not exist."
            exit 1
        fi
        $SERVICE_SH stop -c $CONFIG
        sleep 5
        $SERVICE_SH start -c $CONFIG
        ;;

  supervise)
       #
       # Under control of daemontools supervise monitor which
       # handles restarts and shutdowns via the svc program.
       #
        RUN_ARGS="$JAVA_OPTS -Duser.dir=$SERVICE_ROOT -cp $CLASSPATH $JAVA_CLASSNAME $JAVA_ARGS"
        RUN_CMD="$JAVA $RUN_ARGS"
         exec $RUN_CMD
         ;;

  check)
        echo "Checking arguments to service: "
        echo "SERVICE_PID    =  $SERVICE_PID"
        echo "JAVA_OPTS      =  $JAVA_OPTS"
        echo "JAVA           =  $JAVA"
        echo "CLASSPATH      =  $CLASSPATH"
        echo "JAVA_CLASSNAME =  $JAVA_CLASSNAME"
        echo "JAVA_ARGS      =  $JAVA_ARGS"
        echo

        if [ -f $SERVICE_PID ]
        then
            echo "Service running pid="`cat $SERVICE_PID`
            exit 0
        fi
        exit 1
        ;;

  *)
        usage
        ;;
esac

exit 0
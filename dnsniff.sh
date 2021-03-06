#!/bin/bash

ENC="wpa"
SSID="to_replace"
PWD="to_replace"
INTERFACE="to_replace"
CHANNEL="to_replace"

DB_FILE="/home/pi/dns.db"
LOG_FILE="/home/pi/dns.log" # can be replaced with '/dev/stderr' if running in foreground
DOT11DECRYPT_PREFIX="/home/pi/dot11decrypt/build/"

function _kill_all() {
    [ -n "$CPID1" ] && ((ps -p $CPID1 2>&1 > /dev/null) ||  (kill -2 $CPID1 2>&1 >/dev/null || kill -9 $CPID1)) && wait $CPID1
}

trap "_kill_all" 0

if [ `whoami` != "root" ]
then
    echo "This script needs root privileges"
    exit 1
fi

ifconfig $INTERFACE down
iwconfig $INTERFACE mode monitor
ifconfig $INTERFACE up
iwconfig $INTERFACE channel $CHANNEL
ifconfig $INTERFACE up

if [[ ! -f "$DB_FILE" ]]; then # create the database file if it does not exists
    touch "$DB_FILE"
    sqlite3 "$DB_FILE" <<< "
CREATE TABLE DNS (TIMESTAMP real,MAC_SRC,MAC_DST,IP_SRC,IP_DST,URL,STATUS_CODE);"
fi

# Since we only write small amount of text, we consider the buffer of the system call 'write' to be large enough
# and a concurrent processes writing on the same file should still be fine (no text interlacing).

echo -n "" > "$LOG_FILE"
${DOT11DECRYPT_PREFIX}/dot11decrypt $INTERFACE "${ENC}:${SSID}:${PWD}" > >(awk '{printf strftime("%D %T") " " $0 "\n"; fflush();}' >> $LOG_FILE) &
CPID1=$!
echo "Process $CPID1 launched in background" >> $LOG_FILE


while ! [ -e "/sys/class/net/tap0" ]; do sleep 1; done # wait for the interface to be created (could do the same whith events, but lazy)

tcpdump -tt -n -e -l -s 0 -i tap0 dst port 53 |
    gawk 'match($0,/^(\w+\.\w+) ([0-9a-f:]{17}) > ([0-9a-f:]{17}).* (\w+\.\w+\.\w+\.\w+)\.\w+ > (\w+\.\w+\.\w+\.\w+).*\? (.*)\. .*?$/,g) {
    "curl -o /dev/null -m 5 --silent --head --write-out '%{http_code}' " g[6] | getline status_code;
    printf "INSERT INTO DNS VALUES (\"" g[1]"\",\""g[2]"\",\""g[3]"\",\""g[4]"\",\""g[5]"\",\""g[6]"\",\""status_code"\");\n" > "/dev/stdout"; fflush("/dev/stdout");}' |
    flock -x "$DB_FILE" -c "sqlite3 $DB_FILE"

# add the following line to the awk command if you want a more complete log
#    printf "%10s %17s %17s %15s %15s %-s\n",strftime("%D %T",g[1]),g[2],g[3],g[4],g[5],g[6] > "$LOG_FILE"; fflush("$LOG_FILE");

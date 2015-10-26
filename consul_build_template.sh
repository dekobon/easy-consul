#!/usr/bin/env bash

# Here we redirect the STDOUT and the STDERR to a log file so that we can debug
# things when they go wrong when starting up an instance.

# Close STDOUT file descriptor
exec 1<&-
# Close STDERR FD
exec 2<&-

# Open STDOUT as $LOG_FILE file for read and write.
exec 1<>/var/log/install-`date +%s`.log

# Redirect STDERR to STDOUT
exec 2>&1

##############################################################################
# Consul setup and installation script
##############################################################################

CONSUL_DATA_DIR="/var/lib/consul"
CONSUL_UI_DIR="/usr/local/share/consul-ui"
TEMP_DIR="/tmp/consul-install"
CONSUL_VERSION="0.5.2"
CHECKSUMS="171cf4074bfca3b1e46112105738985783f19c47f4408377241b868affa9d445 ${TEMP_DIR}/${CONSUL_VERSION}_linux_amd64.zip
ad883aa52e1c0136ab1492bbcedad1210235f26d59719fb6de3ef6464f1ff3b1 ${TEMP_DIR}/${CONSUL_VERSION}_web_ui.zip"

if [ -d "${CONSUL_DATA_DIR}" ]; then
    echo "Consul already installed. Exiting"
    exit 0
fi

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# System dependencies
apt-get -qq -y update
apt-get -q -y install wget unzip unattended-upgrades jq \
                      bind9 bind9utils

# Enable automatic security updates
cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

mkdir -p ${TEMP_DIR}

# Download Consul and UI
wget --quiet -O ${TEMP_DIR}/${CONSUL_VERSION}_linux_amd64.zip "https://dl.bintray.com/mitchellh/consul/${CONSUL_VERSION}_linux_amd64.zip"
wget --quiet -O ${TEMP_DIR}/${CONSUL_VERSION}_web_ui.zip "https://dl.bintray.com/mitchellh/consul/${CONSUL_VERSION}_web_ui.zip"
echo "${CHECKSUMS}" | sha256sum -c --strict

# Install Consul into path
pushd .
    cd ${TEMP_DIR}
    mv ${CONSUL_VERSION}_linux_amd64.zip consul.zip
    mv ${CONSUL_VERSION}_web_ui.zip webui.zip
    unzip -o consul.zip
    cp -vf consul /usr/local/bin/
    unzip -o webui.zip
    mv -vf dist ${CONSUL_UI_DIR}
popd

rm -rf ${TEMP_DIR}

cat << 'EOF' > /usr/local/bin/server_alias
#!/usr/bin/env bash

if [ -n "$(which mdata-get)" ]; then
    MDATA_GET_PATH="$(which mdata-get)"
elif [ -f /usr/sbin/mdata-get ]; then
    MDATA_GET_PATH="/usr/sbin/mdata-get"
else
    hostname
    exit 0
fi

ALIAS="$(${MDATA_GET_PATH} sdc:alias)"

if [ -n "${ALIAS}" ]; then
    echo "${ALIAS}"
else
    hostname
fi
EOF
chmod +x /usr/local/bin/server_alias

cat << 'EOF' > /etc/init/server-alias.conf
description "Writes the server alias to a file"

start on runlevel [2345]
stop on runlevel [!2345]

script
    /usr/local/bin/server_alias > /etc/server_alias
end script
EOF

# Consul setup
mkdir -p ${CONSUL_DATA_DIR}
useradd -M -d ${CONSUL_DATA_DIR} consul || echo "Skipping user creation"
mkdir -p /etc/consul.d/{bootstrap,server,client}
chown consul:consul ${CONSUL_DATA_DIR}

cat << 'EOF' > /usr/local/bin/proclimit
#!/usr/bin/env bash

if [[ -d /native ]]; then
    PATH=$PATH:/native/usr/bin
fi

set -o errexit
if [[ -n ${TRACE} ]]; then
    set -o xtrace
fi

# CN parameters
CORES=$(kstat -C -m cpu_info -c misc -s core_id | wc -l | tr -d ' ')
PHYS_MEM=$(kstat -C -m unix -n system_pages -c pages -s physmem | cut -d':' -f5)
PAGESIZE=$(pagesize)
TOTAL_MEMORY=$(echo "${PHYS_MEM} ${PAGESIZE} * pq" | dc)

# zone parameters
ZONE_MEMORY=$(kstat -C -m memory_cap -c zone_memory_cap -s physcap | cut -d':' -f5)

# our fraction of the total memory on the CN
MEMORY_SHARE=$(echo "8k$ZONE_MEMORY $TOTAL_MEMORY / pq" | dc)

# best guess as to how many CPUs we should pretend like we have for tuning
CPU_GUESS=$(echo "${CORES} ${MEMORY_SHARE} * pq" | dc)

# round that up to a positive integer
echo ${CPU_GUESS} | awk 'function ceil(valor) { return (valor == int(valor) && value != 0) ? valor : int(valor)+1 } { printf "%d", ceil($1) }'

exit 0
EOF
chmod +x /usr/local/bin/proclimit

PROC_LIMIT=$(/usr/local/bin/proclimit)

cat << 'EOF' > /etc/init/consul-bootstrap.conf
description "Consul bootstrap process"

start on runlevel [2345]
stop on runlevel [!2345]

respawn

setuid consul
setgid consul

manual

script
    if [ -f "/etc/service/consul" ]; then
        . /etc/service/consul
    fi

    # Don't use too many processes - we are just bootstrapping
    export GOMAXPROCS="2"
    export PRIVATE_IP="$(ip -4 addr show eth1 | grep -Po 'inet \K[\d.]+')"
    export NODE_NAME="$(cat /etc/server_alias)"
    exec consul agent -node=${NODE_NAME} -bind=${PRIVATE_IP} -config-dir /etc/consul.d/bootstrap ${CONSUL_FLAGS}
end script
EOF

cat << 'EOF' > /etc/init/consul-server.conf
description "Consul server process"

start on started server-alias
stop on runlevel [!2345]

respawn

setuid consul
setgid consul

script
    if [ -f "/etc/service/consul" ]; then
        . /etc/service/consul
    fi

    # Based the amount of Go process off of the zone size
    export GOMAXPROCS="echo $(($(/usr/local/bin/proclimit) + 1))"
    export PUBLIC_IP="$(ip -4 addr show eth0 | grep -Po 'inet \K[\d.]+')"
    export PRIVATE_IP="$(ip -4 addr show eth1 | grep -Po 'inet \K[\d.]+')"
    export NODE_NAME="$(cat /etc/server_alias)"
    exec consul agent -node=${NODE_NAME} -bind=0.0.0.0 -advertise=${PRIVATE_IP} -client=0.0.0.0 -config-dir /etc/consul.d/server ${CONSUL_FLAGS}
end script
EOF

# Reload upstart config so that consul is available
initctl reload-configuration
echo "Attempting to stop consul server in case it auto-started"
initctl stop consul-server || true
echo "Attempting to stop consul bootstrap in case it auto-started"
initctl stop consul-bootstrap || true

initctl start server-alias

# We've finished the Consul install, now let's setup BIND
service bind9 stop

mkdir -p /etc/named
cat << 'EOF' > /etc/named/consul.conf
zone "consul" IN {
  type forward;
  forward only;
  forwarders { 127.0.0.1 port 8600; };
};
EOF

cat << 'EOF' > /etc/bind/named.conf.options
include "/etc/named/consul.conf";
acl goodclients {
    192.168.0.0/16;
    172.16.0.0/12;
    10.0.0.0/8;
    localhost;
    localnets;
};
options {
    directory "/var/cache/bind";
    forwarders {
         8.8.8.8;
         8.8.4.4;
    };

    recursion yes;
    allow-query { goodclients; };

    //========================================================================
    // If BIND logs error messages about the root key being expired,
    // you will need to update your keys.  See https://www.isc.org/bind-keys
    //========================================================================
    forward only;
    dnssec-enable yes;
    dnssec-validation yes;

    auth-nxdomain no;    # conform to RFC1035
    listen-on-v6 { any; };
};
EOF

if [[ $PROC_LIMIT -lt 4 ]]; then
    BIND_PROCS=$(( $PROC_LIMIT + 1 ))
else
    BIND_PROCS=$PROC_LIMIT
fi

cat << 'EOF' > /etc/default/bind9
# run resolvconf?
RESOLVCONF=no

# startup options for the server
PROCS=$(( $(/usr/local/bin/proclimit) + 1 ))
OPTIONS="-n $PROCS -u bind"
EOF

service bind9 start

echo "Finished" > ${CONSUL_DATA_DIR}/installed.txt

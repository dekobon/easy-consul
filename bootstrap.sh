#!/usr/bin/env bash

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

npm install git://github.com/dekobon/smartdc-selection.git

# JPC
#t4-standard-128M
#PACKAGE_ID="8b2288b6-efcf-4e20-df2c-e6ad6219b501"

TMP_SETTINGS=$(exec bash $DIR/temporary.sh consul)

# Load in the data center settings first
node ./node_modules/.bin/choose-dc $TMP_SETTINGS
source $TMP_SETTINGS

node ./node_modules/.bin/choose-package --url $SDC_URL $TMP_SETTINGS PACKAGE_ID t4-standard-128M
source $TMP_SETTINGS

UBUNTU_IMAGES="$(sdc-listimages | json -c "this.name == 'ubuntu-14.04'")"

# Dynamically identify the latest Ubuntu image

if [ -z "$UBUNTU_IMAGES" ]; then
    echo 'No ubuntu 14.04 images available. Please install image before continuing.'
    exit 1
fi

IMAGE_ID="$(echo $UBUNTU_IMAGES | json -a id name version | sort -r -k3 | head -n 1 | cut -d' ' -f1)"

echo "Generating shared secret"
# This should be equivelent to "consul keygen"
CONSUL_SHARED_SECRET=$(dd if=/dev/urandom bs=16 count=1 2> /dev/null | base64)

echo "Your shared secret is: ${CONSUL_SHARED_SECRET}"

NETWORKS="$(sdc-listnetworks)"
PUBLIC_NETWORK_ID=$(echo "$NETWORKS" | json -c "this.public == true" | json -a "id" | head -n 1)
PUBLIC_NETWORK_NAME=$(echo $NETWORKS | json -c "this.id == '$PUBLIC_NETWORK_ID'" | json -a "name" | head -n 1)
PRIVATE_NETWORK_ID=$(sdc-fabric network get-default)
PRIVATE_NETWORK_NAME=$(echo $NETWORKS | json -c "this.id == '$PRIVATE_NETWORK_ID'" | json -a "name" | head -n 1)

echo "We have detected the following networks: $(echo $NETWORKS | json -a "name" | paste -s -d, -)"
echo "We have selected this network as the public network: $PUBLIC_NETWORK_NAME"
echo "We have selected this network as the private network: $PRIVATE_NETWORK_NAME"

INSTANCE_01_ID=$(sdc-createmachine \
    --image ${IMAGE_ID} \
    --package ${PACKAGE_ID} \
    --name consul-server-`date +%s` \
    --enable-firewall true \
    --tag server_type=consul-server \
    --networks ${PUBLIC_NETWORK_ID} --networks ${PRIVATE_NETWORK_ID} \
    --script "$DIR/consul_build_template.sh" | \
    json id)

sleep 0.5

INSTANCE_02_ID=$(sdc-createmachine \
    --image ${IMAGE_ID} \
    --package ${PACKAGE_ID} \
    --name consul-server-`date +%s` \
    --enable-firewall true \
    --tag server_type=consul-server \
    --networks ${PUBLIC_NETWORK_ID} --networks ${PRIVATE_NETWORK_ID} \
    --script "$DIR/consul_build_template.sh" | \
    json id)

sleep 0.5

INSTANCE_03_ID=$(sdc-createmachine \
    --image ${IMAGE_ID} \
    --package ${PACKAGE_ID} \
    --name consul-server-`date +%s` \
    --enable-firewall true \
    --tag server_type=consul-server \
    --networks ${PUBLIC_NETWORK_ID} --networks ${PRIVATE_NETWORK_ID} \
    --script "$DIR/consul_build_template.sh" | \
    json id)

if [ -z "${INSTANCE_01_ID}" ]; then
    echo "Instance 01 was not created correctly. Aborting"
    exit 1
fi

if [ -z "${INSTANCE_02_ID}" ]; then
    echo "Instance 02 was not created correctly. Aborting"
    exit 1
fi

if [ -z "${INSTANCE_03_ID}" ]; then
    echo "Instance 02 was not created correctly. Aborting"
    exit 1
fi

echo "Instance 01 id: ${INSTANCE_01_ID}"
echo "Instance 02 id: ${INSTANCE_02_ID}"
echo "Instance 03 id: ${INSTANCE_03_ID}"

echo "Creating firewall rules"
echo "If you want to open communication with consul and the outside world,"
echo "you will need to enable the relevant firewall rules. To list, run: sdc-listfirewallrules"

RULES="$(sdc-listfirewallrules | json -a 'rule')"

function add_rule_once {
    [ $(echo $RULES | grep -c "$1") -eq 0 ] && sdc-createfirewallrule \
        --enabled $3 \
        --description "$2" \
        --rule "$1" > /dev/null
}

# Allow communication between consul servers
add_rule_once "FROM tag server_type = consul-server TO tag server_type = consul-server ALLOW tcp PORT 8300" \
              "Allow conns between Docker private net and Consul agent port" \
              "true"

add_rule_once "FROM tag server_type = consul-server TO tag server_type = consul-server ALLOW tcp PORT 8301" \
              "Gossip protocol rules for the servers being created" \
              "true"

add_rule_once "FROM tag server_type = consul-server TO tag server_type = consul-server ALLOW tcp PORT 8302" \
              "Allow conns between Docker private net and Consul serf wan port" \
              "true"

add_rule_once "FROM tag server_type = consul-server  TO tag server_type = consul-server ALLOW tcp PORT 8400" \
              "Allow conns between Docker private net and Consul CLI RPC port" \
              "true"

add_rule_once "FROM tag server_type = consul-server  TO tag server_type = consul-server ALLOW tcp PORT 8500" \
              "Allow conns between Docker private net and Consul HTTP API port" \
              "true"

add_rule_once "FROM tag server_type = consul-server  TO tag server_type = consul-server ALLOW udp PORT 8600" \
              "Allow conns between Docker private net and Consul DNS port" \
              "true"

# Public rules
add_rule_once "FROM any TO tag server_type = consul-server ALLOW tcp PORT 8300" \
              "Allow public conns to Consul agent port" \
              "false"

add_rule_once "FROM any TO tag server_type = consul-server ALLOW tcp PORT 8301" \
              "Allow public conns to Consul serf lan port" \
              "false"

add_rule_once "FROM any TO tag server_type = consul-server ALLOW tcp PORT 8302" \
              "Allow public conns to Consul serf wan port" \
              "false"

add_rule_once "FROM any TO tag server_type = consul-server ALLOW tcp PORT 8400" \
              "Allow public conns to Consul CLI RPC port" \
              "false"

add_rule_once "FROM any TO tag server_type = consul-server ALLOW tcp PORT 8500" \
              "Allow public conns to Consul HTTP API port" \
              "false"

add_rule_once "FROM any TO tag server_type = consul-server ALLOW udp PORT 8600" \
              "Allow public conns to Consul DNS port" \
              "false"

add_rule_once "FROM any TO tag server_type = consul-server ALLOW udp PORT 53" \
              "Allow public conns DNS port" \
              "false"

# Docker rules
add_rule_once "FROM tag sdc_docker TO tag server_type = consul-server ALLOW tcp PORT 8300" \
              "Allow conns between Docker private net and Consul agent port" \
              "true"

add_rule_once "FROM tag sdc_docker  TO tag server_type = consul-server ALLOW tcp PORT 8301" \
              "Allow conns between Docker private net and Consul serf lan port" \
              "true"

add_rule_once "FROM tag sdc_docker  TO tag server_type = consul-server ALLOW tcp PORT 8302" \
              "Allow conns between Docker private net and Consul serf wan port" \
              "true"

add_rule_once "FROM tag sdc_docker  TO tag server_type = consul-server ALLOW tcp PORT 8400" \
              "Allow conns between Docker private net and Consul CLI RPC port" \
              "true"

add_rule_once "FROM tag sdc_docker  TO tag server_type = consul-server ALLOW tcp PORT 8500" \
              "Allow conns between Docker private net and Consul HTTP API port" \
              "true"

add_rule_once "FROM tag sdc_docker  TO tag server_type = consul-server ALLOW udp PORT 8600" \
              "Allow conns between Docker private net and Consul DNS port" \
              "true"

add_rule_once "FROM tag sdc_docker TO tag server_type = consul-server ALLOW udp PORT 53" \
              "Allow conns DNS port from Docker instances" \
              "true"

# SSH rules
add_rule_once  "FROM any TO tag server_type = consul-server ALLOW tcp PORT 22" \
               "Allow conns to Consul server ssh port" \
               "true"

echo "Waiting for first consul node to come online"
while [ "$(sdc-getmachine ${INSTANCE_01_ID} | json state)" == "provisioning" ]; do
    echo -n '.'
    sleep 2
done
echo;

INSTANCE_01_PUBLIC_IP="$(sdc-getmachine ${INSTANCE_01_ID} | json 'ips[0]')"
INSTANCE_01_PRIVATE_IP="$(sdc-getmachine ${INSTANCE_01_ID} | json 'ips[1]')"

echo "Instance 01 IP: ${INSTANCE_01_PUBLIC_IP}"

# Copy interpolated bootstrap file
cat << EOF > /tmp/bootstrap-config.json
{
    "bootstrap": true,
    "server": true,
    "data_dir": "/var/lib/consul",
    "datacenter": "earth-1",
    "encrypt": "${CONSUL_SHARED_SECRET}",
    "log_level": "INFO",
    "enable_syslog": false
}
EOF

echo "Waiting for servers to boot core processes"
for i in {1..20}; do
    echo -n '.'
    sleep 3
done
echo;

echo "Waiting for ssh daemon to start on instance 01"
for i in {1..60}; do
    if scp -q -o StrictHostKeyChecking=no /tmp/bootstrap-config.json root@${INSTANCE_01_PUBLIC_IP}:/etc/consul.d/bootstrap/config.json; then
        break;
    else
        sleep 10;
    fi
done

echo "Starting Consul bootstrap"
ssh -o StrictHostKeyChecking=no root@${INSTANCE_01_PUBLIC_IP} 'initctl start consul-bootstrap'

echo "Waiting for second node to come online"
while [ "$(sdc-getmachine ${INSTANCE_01_ID} | json state)" == "provisioning" ]; do
    echo -n '.'
    sleep 1
done
echo;

INSTANCE_02_PUBLIC_IP="$(sdc-getmachine ${INSTANCE_02_ID} | json 'ips[0]')"
INSTANCE_02_PRIVATE_IP="$(sdc-getmachine ${INSTANCE_02_ID} | json 'ips[1]')"

echo "Instance 02 IP: ${INSTANCE_02_PUBLIC_IP}"

echo "Waiting for third node to come online"
while [ "$(sdc-getmachine ${INSTANCE_01_ID} | json state)" == "provisioning" ]; do
    echo -n '.'
    sleep 1
done
echo;

INSTANCE_03_PUBLIC_IP="$(sdc-getmachine ${INSTANCE_03_ID} | json 'ips[0]')"
INSTANCE_03_PRIVATE_IP="$(sdc-getmachine ${INSTANCE_03_ID} | json 'ips[1]')"

echo "Instance 03 IP: ${INSTANCE_03_PUBLIC_IP}"

# We build out the server config for all of the instances

cat << EOF > /tmp/instance_01.json
{
    "bootstrap": false,
    "server": true,
    "data_dir": "/var/lib/consul",
    "ui_dir": "/usr/local/share/consul-ui",
    "datacenter": "earth-1",
    "encrypt": "${CONSUL_SHARED_SECRET}",
    "log_level": "INFO",
    "enable_syslog": true,
    "start_join": ["${INSTANCE_02_PRIVATE_IP}", "${INSTANCE_03_PRIVATE_IP}"]
}
EOF

cat << EOF > /tmp/instance_02.json
{
    "bootstrap": false,
    "server": true,
    "data_dir": "/var/lib/consul",
    "ui_dir": "/usr/local/share/consul-ui",
    "datacenter": "earth-1",
    "encrypt": "${CONSUL_SHARED_SECRET}",
    "log_level": "INFO",
    "enable_syslog": true,
    "start_join": ["${INSTANCE_01_PRIVATE_IP}", "${INSTANCE_03_PRIVATE_IP}"]
}
EOF

cat << EOF > /tmp/instance_03.json
{
    "bootstrap": false,
    "server": true,
    "data_dir": "/var/lib/consul",
    "ui_dir": "/usr/local/share/consul-ui",
    "datacenter": "earth-1",
    "encrypt": "${CONSUL_SHARED_SECRET}",
    "log_level": "INFO",
    "enable_syslog": true,
    "start_join": ["${INSTANCE_01_PRIVATE_IP}", "${INSTANCE_02_PRIVATE_IP}"]
}
EOF

echo "Copying server configuration to instance 01"
scp -q -o StrictHostKeyChecking=no /tmp/instance_01.json root@${INSTANCE_01_PUBLIC_IP}:/etc/consul.d/server/config.json || echo -n '.'; sleep 2;

echo "Waiting for ssh daemon to start on instance 02"
for i in {1..60}; do
    echo "Copying server configuration to instance 02"
    if scp -q -o StrictHostKeyChecking=no /tmp/instance_02.json root@${INSTANCE_02_PUBLIC_IP}:/etc/consul.d/server/config.json; then
        echo "Starting consul server on instance 02"
        ssh -o StrictHostKeyChecking=no root@${INSTANCE_02_PUBLIC_IP} 'initctl start consul-server'
        break;
    else
        sleep 5;
    fi
done

echo "Waiting for ssh daemon to start on instance 03"
for i in {1..60}; do
    echo "Copying server configuration to instance 03"
    if scp -q -o StrictHostKeyChecking=no /tmp/instance_03.json root@${INSTANCE_03_PUBLIC_IP}:/etc/consul.d/server/config.json; then
        echo "Starting consul server on instance 03"
        ssh -o StrictHostKeyChecking=no root@${INSTANCE_03_PUBLIC_IP} 'initctl start consul-server'
        break;
    else
        sleep 5;
    fi
done

echo "Stopping bootstrap configuration and enabling server configuration on instance 01"
ssh -o StrictHostKeyChecking=no root@${INSTANCE_01_PUBLIC_IP} 'if ( initctl status consul-bootstrap | grep start ); then initctl stop consul-bootstrap; fi'
ssh -o StrictHostKeyChecking=no root@${INSTANCE_01_PUBLIC_IP} 'initctl start consul-server'

echo "Cleaning up temp files"

rm -f /tmp/bootstrap-config.json \
      /tmp/instance_01.json \
      /tmp/instance_02.json \
      /tmp/instance_03.json

echo "Consul private network addresses: [$INSTANCE_01_PRIVATE_IP, $INSTANCE_02_PRIVATE_IP, $INSTANCE_03_PRIVATE_IP]"

CONSUL_PATH="$(which consul)"

if [ -z ${CONSUL_PATH} ]; then
    exit 0;
fi

echo "Consul was found on the path. Running additional tests."

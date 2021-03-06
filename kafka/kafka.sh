#!/bin/bash
#    Copyright 2015 Google, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
# This script installs Apache Kafka (http://kafka.apache.org) on a Google Cloud
# Dataproc cluster. 

set -euxo pipefail

readonly KAFKA_PROP_FILE='/etc/kafka/conf/server.properties'

function update_apt_get() {
  for ((i = 0; i < 10; i++)); do
    if apt-get update; then
      return 0
    fi
    sleep 5
  done
  return 1
}

function err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $@" >&2
  return 1
}

function install_and_configure_kafka_server() {
  # Find zookeeper list first, before attempting any installation.
  local zookeeper_client_port
  zookeeper_client_port=$(grep 'clientPort' /etc/zookeeper/conf/zoo.cfg \
    | cut -d '=' -f 2)
  
  local zookeeper_list
  zookeeper_list=$(grep '^server\.' /etc/zookeeper/conf/zoo.cfg \
    | cut -d '=' -f 2 \
    | cut -d ':' -f 1 \
    | sed "s/$/:${zookeeper_client_port}/" \
    | xargs echo  \
    | sed "s/ /,/g")

  if [[ -z "${zookeeper_list}" ]]; then
    # Didn't find zookeeper quorum in zoo.cfg, but possibly workers just didn't
    # bother to populate it. Check if YARN HA is configured.
    zookeeper_list=$(bdconfig get_property_value --configuration_file \
      /etc/hadoop/conf/yarn-site.xml \
      --name yarn.resourcemanager.zk-address 2>/dev/null)
  fi

  # If all attempts failed, error out.
  if [[ -z "${zookeeper_list}" ]]; then
    err 'Failed to find configured Zookeeper list; try --num-masters=3 for HA'
  fi

  # Install Kafka from Dataproc distro.
  apt-get install -y kafka-server || dpkg -l kafka-server \
    || err 'Unable to install and find kafka-server on worker node.'

  mkdir -p /var/lib/kafka-logs
  chown kafka:kafka -R /var/lib/kafka-logs

  # Note: If modified to also run brokers on master nodes, this logic for
  # generating broker_id will need to be changed.
  local broker_id
  broker_id=$(hostname | sed 's/.*-w-\([0-9]\)*.*/\1/g')
  sed -i 's|log.dirs=/tmp/kafka-logs|log.dirs=/var/lib/kafka-logs|' \
    "${KAFKA_PROP_FILE}"
  sed -i 's|^\(zookeeper\.connect=\).*|\1'${zookeeper_list}'|' \
    "${KAFKA_PROP_FILE}"
  sed -i 's,^\(broker\.id=\).*,\1'${broker_id}',' \
    "${KAFKA_PROP_FILE}"
  echo 'delete.topic.enable = true' >> "${KAFKA_PROP_FILE}"

  # Start Kafka.
  service kafka-server restart
}

function main() {
  local role
  role="$(/usr/share/google/get_metadata_value attributes/dataproc-role)"
  update_apt_get || err 'Unable to update packages lists.'

  # Only run the installation on workers; verify zookeeper on master(s).
  if [[ "${role}" == 'Master' ]]; then
    service zookeeper-server status \
      || err 'Required zookeeper-server not running on master!'
    # On master nodes, just install kafka libs but not kafka-server.
    apt-get install -y kafka \
      || err 'Unable to install kafka libraries on master!'
  else
    # Run installation on workers.
    install_and_configure_kafka_server
  fi

}

main

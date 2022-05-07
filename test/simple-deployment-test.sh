#! /usr/bin/env bash

THISDIR=$(dirname ${BASH_SOURCE[0]})
source ${THISDIR}/test-lib.sh

if [ $(uname) = "Darwin" ]; then
    PODMAN=/usr/local/bin/docker
else
    PODMAN=/usr/bin/podman
fi

# Names of the container
FIRST_MARIADB_CONTAINER="mariadb_database1"
SECOND_MARIADB_CONTAINER="mariadb_database2"
THIRD_MARIADB_CONTAINER="mariadb_database3"
TESTING_MARIADB_CONTAINER="mariadb_testing"
GARBD_CONTAINER="galera_arbitrator"

# IP adresses
FIRST_MARIADB_CONTAINER_IP="10.11.0.3"
SECOND_MARIADB_CONTAINER_IP="10.11.0.4"
THIRD_MARIADB_CONTAINER_IP="10.11.0.6"
TESTING_MARIADB_CONTAINER_IP="10.11.0.10"
GARBD_CONTAINER_IP="10.11.0.5"

# Docker tags for images
MARIADB_IMAGE_TAG="quay.io/ljavorsk/mariadb-galera"
GARBD_IMAGE_TAG="quay.io/ljavorsk/garbd"

USERNAME="user"
PASS="pass"

COMMON_MARIADB_OPTIONS="-e MYSQL_USER=$USERNAME -e MYSQL_PASSWORD=$PASS -e MYSQL_DATABASE=db"
INTERNAL_NETWORK_NAME="galera_cluster_network"

NUM_OF_TESTS=7
PASSED_TESTS=0

# Source from ./run
# Slightly updated by ljavorsk
# 1st arg - IP of the MariaDB server container which will be connected through the client
# 2nd arg - SQL command that will be run on the MariaDB server with the IP from 1st argument
function mysql_cmd() {
  local container_ip="$1"; shift
  local sql_command="$1"; shift
  $PODMAN exec -u 27 $TESTING_MARIADB_CONTAINER mysql --host "$container_ip" -u"$USERNAME" -p"$PASS" -e "$sql_command" db
}

# Source from ./run
# Slightly updated by ljavorsk
# 1st arg - Name on which container the test will be performed
# 2nd arg - IP of the container in the 1st arg
# 3rd arg (In case of cluster_size checking) - Expected number of nodes in cluster
function test_connection() {
  local name=$1 ; shift
  local ip=$1 ; shift
  # If the cluster_size will be tested there will be third argument
  local expected_cluster_size=$@
  local max_attempts=8
  local sleep_time=2
  failed_to_connect=1
  local i
  local status=''
  for i in $(seq $max_attempts); do
    local status=$($PODMAN inspect -f '{{.State.Status}}' ${name})
    if [ "${status}" != 'running' ] ; then
      break;
    fi
    echo -n "."
    if mysql_cmd "$ip" "SELECT 1;"&> /dev/null; then
      failed_to_connect=0

      # This will be exectuted only for the testing MariaDB server
      if [ $expected_cluster_size -eq 0 ] ; then
        return 0
      fi

      if [[ $(mysql_cmd "$ip" "SHOW STATUS LIKE 'wsrep_cluster_size'" | grep wsrep_cluster_size | cut -f 2) -eq $expected_cluster_size ]] ; then
        echo -e " [\e[32m PASSED \e[0m]"
        PASSED_TESTS=$(($PASSED_TESTS+1))
        return 0
      fi
    fi
    sleep $sleep_time
  done

  echo -e " [\e[31m FAILED \e[0m]"

  if [ $failed_to_connect -eq 1 ] ; then
    echo "Failed to connect to the MariaDB server named "$name""

    if [ "${status}" == 'running' ] ; then
      echo "  Container is still running."
    else
      local exit_status=$($PODMAN inspect -f '{{.State.ExitCode}}' ${name})
      echo "  Container finised with exit code ${exit_status}."
    fi
  else
    echo "The cluster_size doesn't correspond with the reference value in test."
  fi

  return 1
}

printf "\n"
echo "###   SETUP     ###"

# Initial clean-up if any of the container is already existing
echo "Cleaning the junk from the previous tests"
$PODMAN stop $FIRST_MARIADB_CONTAINER $SECOND_MARIADB_CONTAINER $THIRD_MARIADB_CONTAINER $TESTING_MARIADB_CONTAINER $GARBD_CONTAINER &> /dev/null || true


# Create docker network if it's not existing
$PODMAN network inspect $INTERNAL_NETWORK_NAME >/dev/null 2>&1 || \
    $PODMAN network create $INTERNAL_NETWORK_NAME --subnet=10.11.0.0/16 > /dev/null


# Create testing mariadb container
# It needs to be created beforehand because it will test the connection on the other containers
echo -n "Starting the MariaDB container used for testing the connection to servers "

$PODMAN run -d --rm --network=$INTERNAL_NETWORK_NAME --ip=$TESTING_MARIADB_CONTAINER_IP --name $TESTING_MARIADB_CONTAINER $COMMON_MARIADB_OPTIONS $MARIADB_IMAGE_TAG > /dev/null

test_connection $TESTING_MARIADB_CONTAINER $TESTING_MARIADB_CONTAINER_IP 0

# Start the mariadb-galera container, which will initialize the cluster
$PODMAN run -d --rm --network=$INTERNAL_NETWORK_NAME --ip=$FIRST_MARIADB_CONTAINER_IP --name $FIRST_MARIADB_CONTAINER $COMMON_MARIADB_OPTIONS -e GALERA_INIT= $MARIADB_IMAGE_TAG > /dev/null

# Testing
printf "\n\n"
echo "###   TESTING   ###"

##### TEST 1
echo -en "1: Testing the \e[34m initialization \e[0m of the galera cluster ."

# Wait till the server is up
test_connection $FIRST_MARIADB_CONTAINER $FIRST_MARIADB_CONTAINER_IP 1

# Start the Galera Arbitrator image and connect it to the cluster
$PODMAN run -d --rm --network=$INTERNAL_NETWORK_NAME --ip=$GARBD_CONTAINER_IP --name $GARBD_CONTAINER -e CLUSTERS_IP4=$FIRST_MARIADB_CONTAINER_IP $GARBD_IMAGE_TAG > /dev/null

##### TEST 2
echo -en "2: Testing the cluster size \e[34m after garbd connects \e[0m to the cluster ."

# Wait a few seconds to garbd initialization
test_connection $FIRST_MARIADB_CONTAINER $FIRST_MARIADB_CONTAINER_IP 2

# Create another mariadb-server container and connect it to cluster
$PODMAN run -d --rm --network=$INTERNAL_NETWORK_NAME --ip=$SECOND_MARIADB_CONTAINER_IP --name $SECOND_MARIADB_CONTAINER $COMMON_MARIADB_OPTIONS -e CLUSTERS_IP4=$FIRST_MARIADB_CONTAINER_IP,$SECOND_MARIADB_CONTAINER_IP,$GARBD_CONTAINER_IP $MARIADB_IMAGE_TAG > /dev/null

##### TEST 3
echo -en "3: Testing the connection of \e[34m another mariadb-server \e[0m to the cluster ."

test_connection $SECOND_MARIADB_CONTAINER $SECOND_MARIADB_CONTAINER_IP 3

# Test removing the garbd from cluster

##### TEST 4
echo -en "4: Testing \e[34m removing garbd \e[0m from the cluster ..."

$PODMAN stop $GARBD_CONTAINER > /dev/null

test_connection $FIRST_MARIADB_CONTAINER $FIRST_MARIADB_CONTAINER_IP 2

##### TEST 5
echo -en "5: Testing \e[34m removing initial mariadb server \e[0m from the cluster ..."

$PODMAN stop $FIRST_MARIADB_CONTAINER > /dev/null

test_connection $SECOND_MARIADB_CONTAINER $SECOND_MARIADB_CONTAINER_IP 1

##### TEST 6
echo -en "6: Testing the connection of \e[34m new mariadb-server \e[0m to the cluster ."

$PODMAN run -d --rm --network=$INTERNAL_NETWORK_NAME --ip=$THIRD_MARIADB_CONTAINER_IP --name $THIRD_MARIADB_CONTAINER $COMMON_MARIADB_OPTIONS -e CLUSTERS_IP4=$FIRST_MARIADB_CONTAINER_IP,$SECOND_MARIADB_CONTAINER_IP,$GARBD_CONTAINER_IP,$THIRD_MARIADB_CONTAINER_IP $MARIADB_IMAGE_TAG > /dev/null

test_connection $THIRD_MARIADB_CONTAINER $THIRD_MARIADB_CONTAINER_IP 2

##### TEST 7
echo -en "7: Testing the connection of \e[34m new garbd \e[0m to the cluster ."

$PODMAN run -d --rm --network=$INTERNAL_NETWORK_NAME --ip=$GARBD_CONTAINER_IP --name $GARBD_CONTAINER -e CLUSTERS_IP4="$SECOND_MARIADB_CONTAINER_IP $THIRD_MARIADB_CONTAINER_IP" $GARBD_IMAGE_TAG > /dev/null

test_connection $SECOND_MARIADB_CONTAINER $SECOND_MARIADB_CONTAINER_IP 3

# Results
printf "\n\n"
echo "###   RESULTS   ###"
echo $PASSED_TESTS "/" $NUM_OF_TESTS "passed"
printf "\n"

# Cleanup
echo "###   CLEANUP   ###"

echo "Stopping images:"
$PODMAN stop $SECOND_MARIADB_CONTAINER $THIRD_MARIADB_CONTAINER $TESTING_MARIADB_CONTAINER $GARBD_CONTAINER
printf "\n"

echo "Removing docker network:"
$PODMAN network remove $INTERNAL_NETWORK_NAME

# This file is used in the MariaDB Galera operator as a custom Health check test
# It is required to pass a number as the 1st parameter which represents how many
# Galera cluster members are expected to be connected to the cluster.
# Test is used in 2 Health checks...
# 1) Check if the container is part of the Galera cluster (it can be the only node in the cluster)
# 	- In this case the number expected as the 1st parameter is "1"
#
# 2) Check if the container is part of the cluster that has at least 1 more member
# 	- In this case the number expected as the 1st parameter is "2"
#
#
# If this test returns exit code 0, it means that the container has successfully connected to the cluster and
# depending on the which health check is supposed to be checked, the value of the 1st parameter is checked.

test "$(mariadb -e "SHOW STATUS LIKE 'wsrep_cluster_size'" | grep wsrep_cluster_size | cut -f 2)" -ge "$1"

#!/bin/bash

# Copyright 2017 The Openstack-Helm Authors.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -xe

#NOTE: Lint and package chart
: ${OSH_INFRA_PATH:="../openstack-helm-infra"}
for CHART in ceph-mon ceph-osd ceph-client ceph-provisioners; do
  make -C ${OSH_INFRA_PATH} "${CHART}"
done

#NOTE: Deploy command

: ${OSH_EXTRA_HELM_ARGS:=""}
CEPH_PUBLIC_NETWORK="$($OSH_INFRA_PATH/tools/deployment/multinode/kube-node-subnet.sh)"
CEPH_CLUSTER_NETWORK="$($OSH_INFRA_PATH/tools/deployment/multinode/kube-node-subnet.sh)"
[ -s /tmp/ceph-fs-uuid.txt ] || uuidgen > /tmp/ceph-fs-uuid.txt
CEPH_FS_ID="$(cat /tmp/ceph-fs-uuid.txt)"
#NOTE(portdirect): to use RBD devices with Ubuntu kernels < 4.5 this
# should be set to 'hammer'
. /etc/os-release
if [ "x${ID}" == "xubuntu" ] && \
   [ "$(uname -r | awk -F "." '{ print $2 }')" -lt "5" ]; then
  CRUSH_TUNABLES=hammer
else
  CRUSH_TUNABLES=null
fi
tee /tmp/ceph.yaml <<EOF
endpoints:
  identity:
    namespace: openstack
  object_store:
    namespace: ceph
  ceph_mon:
    namespace: ceph
network:
  public: ${CEPH_PUBLIC_NETWORK}
  cluster: ${CEPH_CLUSTER_NETWORK}
deployment:
  storage_secrets: true
  ceph: true
  rbd_provisioner: true
  cephfs_provisioner: true
  client_secrets: false
  rgw_keystone_user_and_endpoints: false
bootstrap:
  enabled: true
conf:
  ceph:
    global:
      fsid: ${CEPH_FS_ID}
  rgw_ks:
    enabled: true
  pool:
    crush:
      tunables: ${CRUSH_TUNABLES}
    target:
      # NOTE(portdirect): 5 nodes, with one osd per node
      osd: 5
      pg_per_osd: 100
  storage:
    osd:
      - data:
          type: directory
          location: /var/lib/openstack-helm/ceph/osd/osd-one
        journal:
          type: directory
          location: /var/lib/openstack-helm/ceph/osd/journal-one
EOF

for CHART in ceph-mon ceph-osd ceph-client ceph-provisioners; do
  helm upgrade --install ${CHART} ${OSH_INFRA_PATH}/${CHART} \
    --namespace=ceph \
    --values=/tmp/ceph.yaml \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_CEPH_DEPLOY}

  #NOTE: Wait for deploy
  ./tools/gate/scripts/wait-for-pods.sh ceph

  #NOTE: Validate deploy
  MON_POD=$(kubectl get pods \
    --namespace=ceph \
    --selector="application=ceph" \
    --selector="component=mon" \
    --no-headers | awk '{ print $1; exit }')
  kubectl exec -n ceph ${MON_POD} -- ceph -s
done
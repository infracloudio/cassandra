#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# variables, with defaults
[ "x${CASSANDRA_DIR}" != "x" ] || CASSANDRA_DIR="$(readlink -f $(dirname "$0")/..)"
[ "x${KUBECONFIG}" != "x" ]    || KUBECONFIG="${HOME}/.kube/config"
[ "x${KUBE_NS}" != "x" ]       || KUBE_NS="default" # FIXME – doesn't work in other namespaces :shrug:

# pre-conditions
command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl needs to be installed"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo >&2 "helm needs to be installed"; exit 1; }

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -c|--kubeconfig)
            KUBECONFIG="$2"  # This sets the KUBECONFIG variable to the next argument.
            shift            # This shifts the arguments to the left, discarding the current argument and moving to the next one.
            shift            # This is an additional shift to move to the argument after the option value.
            ;;
        -ctx|--kubecontext)
            unset KUBECONFIG
            KUBECONTEXT="$2" # This sets the KUBECONTEXT variable to the next argument.
            shift            # This shifts the arguments to the left, discarding the current argument and moving to the next one.
            shift            # This is an additional shift to move to the argument after the option value.
            ;;
        --include-test-stage)
            INCLUDE_TEST_STAGE="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "$KUBECONFIG" ] && [ -z "$KUBECONTEXT" ]; then
    echo "Please provide either the path to the kubeconfig using -c|--kubeconfig option or the kubecontext using -ctx|--kubecontext option."
    exit 1
fi

# This sets the kubeconfig and kubecontext if provided
if [ -n "$KUBECONFIG" ]; then
    export KUBECONFIG="$KUBECONFIG"
fi

if [ -n "$KUBECONTEXT" ]; then
    kubectl config use-context "$KUBECONTEXT"
fi

if ! kubectl get namespace ${KUBE_NS} >/dev/null 2>/dev/null ; then
    kubectl create namespace ${KUBE_NS}
fi

if [ -n "$INCLUDE_TEST_STAGE" ]; then
   
fi

# Add Helm Jenkins Operator repository
echo "Adding Helm repository for Jenkins Operator..."
helm repo add --namespace ${KUBE_NS} jenkins https://raw.githubusercontent.com/jenkinsci/kubernetes-operator/master/chart

# Install Jenkins Operator using Helm
echo "Installing Jenkins Operator..."
#helm upgrade --namespace ${KUBE_NS} --install jenkins-operator jenkins/jenkins-operator --set jenkins.enabled=false --set jenkins.backup.enabled=false --version 0.8.0-beta.2 

echo "Jenkins Operator installed successfully!" # condition to check if above command was success

# deploy jenkins Instance TODO jenkins file parameter
kubectl apply --namespace ${KUBE_NS} -f ${CASSANDRA_DIR}/.build/jenkins-deployment.yaml

TOKEN=$(kubectl  get secret jenkins-operator-credentials-example -o jsonpath="{.data.token}" | base64 --decode)

# Trigger a new build and capture the response headers
response_headers=$(curl -i -X POST http://localhost:8080/job/k8s-e2e/buildWithParameters -u jenkins-operator:$TOKEN --data-urlencode "TEST_STAGES_TO_RUN=$INCLUDE_TEST_STAGE" 2>&1)


queue_url=$(echo "$response_headers" | grep -i "Location" | awk -F ": " '{print $2}' | tr -d '\r')
queue_item_number=$(basename "$queue_url")

# Construct the complete URL to retrieve build information
queue_json_url="http://localhost:8080/queue/item/$queue_item_number/api/json"

# Wait for the build number to become available (querying the API)
build_number=""
while [ -z "$build_number" ] || [ "$build_number" == "null" ]; do
    build_info=$(curl -s "$queue_json_url" -u jenkins-operator:$TOKEN)
    build_number=$(echo "$build_info" | jq -r '.executable.number')
    if [ -z "$build_number" ] || [ "$build_number" == "null" ]; then
        echo "Build number not available yet. Waiting..."
        sleep 5  # Adjust the polling interval as needed
    fi
done

echo "build_number $build_number"
BUILD_DIR=/var/lib/jenkins/jobs/k8s-e2e/builds
POD_NAME=jenkins-example
LATEST_BUILD=$(kubectl exec -it $POD_NAME -- /bin/bash -c "ls -t $BUILD_DIR | head -n 1" | tr -d '\r')

CONSOLE_LOG_FILE="$BUILD_DIR/$build_number/log"

# Define a function to check if "FINISHED" is in the consoleLog
check_finished() {
    kubectl exec -n $KUBE_NS $POD_NAME -- cat "$CONSOLE_LOG_FILE" | grep -q "Finished"
}

# Continuously check for "FINISHED"
while true; do
    if check_finished; then
        echo "Build has finished."
        break
    else
        echo "Build is still in progress."
    fi
    sleep 5  # Adjust the sleep interval as needed
done

LOCAL_DIR=.
mkdir -p $LOCAL_DIR/$build_number
kubectl cp -n $KUBE_NS $POD_NAME:$BUILD_DIR/$build_number/log $LOCAL_DIR/$build_number/log
kubectl cp -n $KUBE_NS $POD_NAME:$BUILD_DIR/$build_number/junitResult.xml $LOCAL_DIR/$build_number/junitResult.xml



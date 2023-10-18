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
        --repo-url)
            REPO_URL="$2"
            shift
            shift;;
        --repo-branch)
            REPO_BRANCH="$2"
            shift
            shift
            ;;
        --targets)
            TARGETS="$2"
            shift
            shift
            ;;
        --tear-down)
            TEAR_DOWN="$2"
            shift
            shift
            ;;
        --help)
            echo "Usage: your_script.sh [options]"
            echo "Options:"
            echo "  -c, --kubeconfig <file>       Specify the path to a Kubeconfig file."
            echo "  -ctx, --kubecontext <context> Specify the Kubernetes context to use."
            echo "  --include-test-stage <value>  Include test stage/s."
            echo "  --repo-url <url>              Specify the repository URL."
            echo "  --repo-branch <branch>        Specify the repository branch."
            echo "  --targets <target>            Specify the build targets."
            echo "  --tear-down <value>           Tear down Jenkins Instance, true or false."
            echo "  --help                        Show this help message."
            exit 0 
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
    # The variable is not empty, so it has a value
    echo "INCLUDE_TEST_STAGE is not empty. Its value is: $INCLUDE_TEST_STAGE"
else
    # The variable is empty, so assign a default value
    INCLUDE_TEST_STAGE="lint,stress,fqltool"
    echo "INCLUDE_TEST_STAGE is empty. Assigning default value: $INCLUDE_TEST_STAGE"
fi


if [ -n "$TARGETS" ]; then
    # The variable is not empty, so it has a value
    echo "TARGETS is not empty. Its value is: $TARGETS"
else
    # The variable is empty, so assign a default value
    TARGETS=".jenkins/job/DslJob.jenkins"
    echo "TARGETS is empty. Assigning default value: $TARGETS"
fi

if [ -n "$REPO_URL" ]; then
    # The variable is not empty, so it has a value
    echo "REPO_URL is not empty. Its value is: $REPO_URL"
else
    # The variable is empty, so assign a default value
    REPO_URL="https://github.com/infracloudio/cassandra.git"
    echo "REPO_URL is empty. Assigning default value: $REPO_URL"
fi

if [ -n "$REPO_BRANCH" ]; then
    # The variable is not empty, so it has a value
    echo "REPO_BRANCH is not empty. Its value is: $REPO_BRANCH"
else
    # The variable is empty, so assign a default value
    REPO_BRANCH="infracloud/cassandra-5.0"
    echo "REPO_BRANCH is empty. Assigning default value: $REPO_BRANCH"
fi

if [ -n "$TEAR_DOWN" ]; then
    # The variable is not empty, so it has a value
    echo "TEAR_DOWN is not empty. Its value is: $TEAR_DOWN"
else
    # The variable is empty, so assign a default value
    TEAR_DOWN=false
    echo "TEAR_DOWN is empty. Assigning default value: $TEAR_DOWN"
fi

sed -e "/targets:/s|:.*$|: \"$TARGETS\"|" \
    -e "/repositoryBranch:/s|:.*$|: \"$REPO_BRANCH\"|" \
    -e "/repositoryUrl:/s|:.*$|: \"$REPO_URL\"|" ${CASSANDRA_DIR}/.build/jenkins-deployment.yaml > ${CASSANDRA_DIR}/.build/jenkins-deployment.yaml

# Add Helm Jenkins Operator repository
echo "Adding Helm repository for Jenkins Operator..."
helm repo add --namespace ${KUBE_NS} jenkins https://raw.githubusercontent.com/jenkinsci/kubernetes-operator/master/chart

# Install Jenkins Operator using Helm
echo "Installing Jenkins Operator..."
helm upgrade --namespace ${KUBE_NS} --install jenkins-operator jenkins/jenkins-operator --set jenkins.enabled=false --set jenkins.backup.enabled=false --version 0.8.0-beta.2 

while ! ( kubectl --namespace ${KUBE_NS} get pods | grep jenkins-operator | grep " 1/1 " | grep -q " Running" ) ; do
        echo "Jenkins installing. Waiting..."
        sleep 5  # Adjust the polling interval as needed
done

echo "Jenkins Operator installed successfully!"

kubectl apply --namespace ${KUBE_NS} -f ${CASSANDRA_DIR}/.build/jenkins-deployment.yaml

while ! ( kubectl --namespace ${KUBE_NS} get pods | grep seed-job-agent | grep " 1/1 " | grep -q " Running" ) ; do
        echo "Jenkins installing. Waiting..."
        sleep 5  # Adjust the polling interval as needed
done

kubectl rollout status deployment/jenkins-operator -n ${KUBE_NS}

# Port-forward the Jenkins service to access it locally
jenkins_pod=$(kubectl get pods -n ${KUBE_NS} -l jenkins-cr=jenkins -o jsonpath='{.items[0].metadata.name}')

nohup kubectl port-forward svc/jenkins-operator-http-jenkins 8080:8080 &
echo "port-forwarding running in background"
# echo "To forward the Jenkins service to another terminal, open a new terminal window and run the following command:"
# echo "kubectl port-forward -n ${KUBE_NS} $jenkins_pod 8080:8080"

TOKEN=$(kubectl  get secret jenkins-operator-credentials-jenkins -o jsonpath="{.data.token}" | base64 --decode)

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
POD_NAME=jenkins-jenkins
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

RESULTS_DIR="${CASSANDRA_DIR}/build/ci_${build_number}"
mkdir -p ${RESULTS_DIR}
kubectl cp -n $KUBE_NS $POD_NAME:${CONSOLE_LOG_FILE} ${RESULTS_DIR}/log

if kubectl exec -n $KUBE_NS $POD_NAME -- test -e $BUILD_DIR/$build_number/junitResult.xml; then
    kubectl cp -n $KUBE_NS $POD_NAME:$BUILD_DIR/$build_number/junitResult.xml ${RESULTS_DIR}/junitResult.xml
else
    # Display a message indicating that junitResult.xml is not generated
    echo "junitResult.xml is not generated."
fi


# kill the port-forwarding process
ps -elf | grep port-forward | head -n1 | awk -F " " '{ print $4 }' | xargs kill -9


if [ $TEAR_DOWN ]; then
    kubectl delete --namespace ${KUBE_NS} -f ${CASSANDRA_DIR}/.build/jenkins-deployment.yaml
fi


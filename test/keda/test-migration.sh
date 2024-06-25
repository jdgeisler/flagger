#!/usr/bin/env bash

# This script runs e2e tests for Canary and migrating from an hpa to a keda scaled object
# Prerequisites: Kubernetes Kind and Istio

set -o errexit

echo '>>> Installing hpa'
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: podinfo
  namespace: test
spec:
  maxReplicas: 4
  metrics:
  - resource:
      name: cpu
      target:
        averageUtilization: 99
        type: Utilization
    type: Resource
  minReplicas: 2
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
EOF


echo '>>> Initialising canaries'
cat <<EOF | kubectl apply -f -
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: podinfo
  namespace: test
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  autoscalerRef:
    apiVersion: autoscaling/v2
    kind: HorizontalPodAutoscaler
    name: podinfo
  progressDeadlineSeconds: 60
  service:
    port: 9898
    portDiscovery: true
    apex:
      annotations:
        test: "annotations-test"
      labels:
        test: "labels-test"
    headers:
      request:
        add:
          x-envoy-upstream-rq-timeout-ms: "15000"
          x-envoy-max-retries: "10"
          x-envoy-retry-on: "gateway-error,connect-failure,refused-stream"
  analysis:
    interval: 15s
    threshold: 15
    maxWeight: 30
    stepWeight: 10
    metrics:
    - name: request-success-rate
      thresholdRange:
        min: 99
      interval: 1m
    webhooks:
      - name: load-test
        url: http://flagger-loadtester.test/
        timeout: 5s
        metadata:
          type: cmd
          cmd: "hey -z 10m -q 10 -c 2 http://podinfo.test:9898/"
          logCmdOutput: "true"
EOF

echo '>>> Waiting for primary to be ready'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test get canary/podinfo | grep 'Initialized' && ok=true || ok=false
    sleep 5
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n flagger-system logs deployment/flagger
        echo "No more retries left"
        exit 1
    fi
done

echo '✔ Canary initialization test passed'

passed=$(kubectl -n test get svc/podinfo -oyaml 2>&1 | { grep annotations-test || true; })
if [ -z "$passed" ]; then
  echo -e '\u2716 podinfo annotations test failed'
  exit 1
fi
passed=$(kubectl -n test get svc/podinfo -oyaml 2>&1 | { grep labels-test || true; })
if [ -z "$passed" ]; then
  echo -e '\u2716 podinfo labels test failed'
  exit 1
fi
passed=$(kubectl -n test get svc/podinfo -o jsonpath='{.spec.selector.app}' 2>&1 | { grep podinfo-primary || true; })
if [ -z "$passed" ]; then
  echo -e '\u2716 podinfo selector test failed'
  exit 1
fi

echo '✔ Canary service custom metadata test passed'

echo '>>> Triggering canary deployment'
kubectl -n test set image deployment/podinfo podinfod=ghcr.io/stefanprodan/podinfo:6.0.1

echo '>>> Waiting for canary promotion'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test describe deployment/podinfo-primary | grep '6.0.1' && ok=true || ok=false
    sleep 10
    kubectl -n flagger-system logs deployment/flagger --tail 1
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n test describe deployment/podinfo
        kubectl -n test describe deployment/podinfo-primary
        kubectl -n flagger-system logs deployment/flagger
        echo "No more retries left"
        exit 1
    fi
done

echo '>>> Waiting for canary finalization'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test get canary/podinfo | grep 'Succeeded' && ok=true || ok=false
    sleep 5
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n flagger-system logs deployment/flagger
        echo "No more retries left"
        exit 1
    fi
done

echo '✔ Canary promotion test passed'

echo '>>> Deleting HPA and installing the keda scaled object'

kubectl delete hpa podinfo -n test

cat <<EOF | kubectl apply -f -
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: podinfo
  namespace: test
  annotations:
    scaledobject.keda.sh/transfer-hpa-ownership: "true"
spec:
  advanced:
    horizontalPodAutoscalerConfig:
      name: podinfo
  scaleTargetRef:
    name: podinfo
  pollingInterval: 10
  cooldownPeriod: 20
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
  - type: prometheus
    metricType: AverageValue
    metadata:
      serverAddress: http://flagger-prometheus.flagger-system:9090
      metricName: http_requests_total
      query: sum(rate(http_requests_total{ app="podinfo" }[30s]))
      threshold: '5'
EOF

echo '>>> Updating canary to reference the scaled object instead of the hpa'

cat <<EOF | kubectl apply -f -
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: podinfo
  namespace: test
spec:
  provider: kubernetes
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: podinfo
  autoscalerRef:
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    name: podinfo
  progressDeadlineSeconds: 60
  service:
    port: 80
    targetPort: 9898
    name: podinfo-svc
    portDiscovery: true
  analysis:
    interval: 15s
    threshold: 10
    iterations: 8
    metrics:
      - name: request-success-rate
        interval: 1m
        thresholdRange:
          min: 99
      - name: request-duration
        interval: 30s
        thresholdRange:
          max: 500
    webhooks:
      - name: load-test
        url: http://flagger-loadtester.test/
        timeout: 5s
        metadata:
          type: cmd
          cmd: "hey -z 2m -q 20 -c 2 http://podinfo-svc-canary.test/"
EOF

sleep 10

echo '>>> Triggering canary deployment'
kubectl -n test set image deployment/podinfo podinfod=ghcr.io/stefanprodan/podinfo:6.0.2

echo '>>> Waiting for canary deployment to be scaled up'
retries=20
count=0
ok=false
until ${ok}; do
    kubectl -n test get deployment/podinfo -oyaml | grep 'replicas: 3' && ok=true || ok=false
    sleep 5
    kubectl -n flagger-system logs deployment/flagger --tail 1
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n flagger-system logs deployment/flagger
        kubectl -n test get deploy/podinfo -oyaml
        echo "No more retries left"
        exit 1
    fi
done

echo '>>> Waiting for canary promotion'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test describe deployment/podinfo-primary | grep '6.0.1' && ok=true || ok=false
    sleep 10
    kubectl -n flagger-system logs deployment/flagger --tail 1
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n flagger-system logs deployment/flagger
        kubectl -n test get httpproxy podinfo -oyaml
        echo "No more retries left"
        exit 1
    fi
done

echo '✔ Canary promotion test passed'

echo '>>> Waiting for canary finalization'
retries=50
count=0
ok=false
until ${ok}; do
    kubectl -n test get canary/podinfo | grep 'Succeeded' && ok=true || ok=false
    sleep 5
    count=$(($count + 1))
    if [[ ${count} -eq ${retries} ]]; then
        kubectl -n flagger-system logs deployment/flagger
        echo "No more retries left"
        exit 1
    fi
done

val=$(kubectl -n test get scaledobject podinfo -o=jsonpath='{.metadata.annotations.autoscaling\.keda\.sh\/paused-replicas}' | xargs)
if [[ "$val" = "0" ]]; then
    echo '✔ Successfully paused autoscaling for target ScaledObject'
else
    echo '⨯ Could not pause autoscaling for target ScaledObject'
fi

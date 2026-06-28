# Metrics Server (HPA prerequisite)

The HorizontalPodAutoscaler in `kubernetes/base/hpa.yaml` scales on CPU
utilization, which requires the Kubernetes Metrics Server to be installed.
EKS does not include it by default, so it must be installed before the scaling
behavior can be demonstrated.

## Installation

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system
```

## Verification

```bash
kubectl top pods -n max-weather
kubectl get hpa -n max-weather weather-api
```

`kubectl top` returning values (not "metrics not available") confirms the HPA
has the data it needs to scale.

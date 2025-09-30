# Ingress controller reports no external connectivity

When the `ingress-nginx` load balancer publishes an IP address but the hosts such as
`kc.<ip>.nip.io` or `argocd.<ip>.nip.io` time out, check the Azure load-balancer
health probe settings. If the probe hits a path that does not return HTTP 200 the
platform will consider every backend node unhealthy and traffic will never reach the
controller pods.

The chart configuration previously pointed the probe at `/is-dynamic-lb-initialized`,
a path that the controller does not expose. Standard probes would therefore fail and
the public IP would accept connections but immediately reset them.

Update the annotation to the controller's built-in health endpoint, `/healthz`:

```yaml
service:
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz
```

After the change syncs, the probe begins reporting healthy and ingress hosts start
responding to HTTP requests.

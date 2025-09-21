# Demo host ingress templates

These manifests define the Keycloak and midPoint ingress objects used by the
`04_configure_demo_hosts` GitHub Actions workflow. The workflow renders the
files via `envsubst` so the nip.io hostnames resolve to the cluster's ingress
IP address without embedding runtime values in the repository.

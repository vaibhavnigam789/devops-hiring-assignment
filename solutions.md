# Kubernetes Debugging Challenges & Solutions

---

## Challenge 1: Deploy the Cluster

### Symptoms Observed
- `terraform init` failed — provider version constraints not satisfiable  
- `terraform apply` failed — multiple errors before any resource was created  

### Tools Used
- `terraform init / terraform validate / terraform apply` — read error messages top-down  
- Text editor to inspect `main.tf` and compare variable names vs actual files  

### Root Causes Found

| # | What Was Broken | Where |
|---|----------------|------|
| 1 | `required_version = ">= 2.0.0"` — Terraform 2.x does not exist | terraform {} block |
| 2 | null provider version `~> 4.0` — does not exist | required_providers |
| 3 | Wrong file name `cluster-config.yaml` | kind_cluster trigger |
| 4 | Wrong variable `var.kube_config_path` | kind create cluster |

### Fix Applied
```diff
- required_version = ">= 2.0.0"
+ required_version = ">= 1.14.0"

- null = { version = "~> 4.0" }
+ null = { version = "~> 3.0" }

- cluster-config.yaml
+ kind-config.yaml

- var.kube_config_path
+ var.kind_config_path
```

### Verification
```bash
kubectl --context kind-sanjay-challenge get nodes
```

---

## Challenge 2: Fix the Broken Deployment (namespace t2)

### Symptoms Observed
- Pods not running (0/3)
- Errors: FailedScheduling, ImagePullBackOff

### Root Causes

| # | Issue | Effect |
|---|------|--------|
| 1 | Pod quota too low | 1 pod blocked |
| 2 | Memory quota insufficient | Pods exceed quota |
| 3 | Image typo | Pull failure |
| 4 | Wrong readiness probe path | Not ready |
| 5 | Missing node labels | Scheduling failure |

### Fix Applied
```diff
- pods: "2"
+ pods: "3"

- requests.memory: "150Mi"
+ requests.memory: "300Mi"

- nginx:1.19-alpne
+ nginx:1.19-alpine

- /healthz
+ /

+ kubectl label node <node> disk=ssd --overwrite
```

---

## Challenge 3: Network Black Hole (namespace t3)

### Symptoms
- Service unreachable
- DNS resolution failed

### Root Causes

| # | Issue | Effect |
|---|------|--------|
| 1 | Deny-all ingress policy | Blocks traffic |
| 2 | Deny-all egress | No outbound |
| 3 | CoreDNS rewrite | DNS failure |

### Fix Applied
- Allow ingress from default
- Allow DNS + egress traffic
- Remove CoreDNS rewrite rule

---

## Challenge 4: Node Recovery (worker2)

### Symptoms
- Node NotReady
- Pods not scheduled

### Root Causes

| # | Issue | Effect |
|---|------|--------|
| 1 | Wrong cgroup driver | kubelet crash |
| 2 | Disk bloat file | Disk pressure |
| 3 | iptables block | API unreachable |
| 4 | Cert renamed | Auth failure |
| 5 | kubelet stopped | Node down |
| 6 | Node cordoned | No scheduling |

### Fix Applied
```bash
# Fix config
sed -i 's/cgroupfsss/systemd/'

# Remove large file
rm -f /var/log/bloat.img

# Fix iptables
iptables -D OUTPUT -p tcp --dport 6443 -j DROP

# Restore cert
mv *.pem.bak *.pem

# Restart kubelet
systemctl start kubelet

# Enable scheduling
kubectl uncordon worker2
```

---

## Challenge 5: TLS Certificate Debugging (namespace t5)

### Symptoms
- Connection failure
- TLS handshake errors

### Root Causes

| # | Issue | Effect |
|---|------|--------|
| 1 | Cert/key swapped | Crash |
| 2 | Wrong CN | Host mismatch |
| 3 | No SAN | TLS rejected |
| 4 | CA double encoded | Invalid cert |

### Fix Applied
```diff
- tls.crt = key
- tls.key = cert
+ correct mapping

+ Add SAN:
subjectAltName=DNS:secure-app.t5.svc.cluster.local

- Base64 encoded CA
+ Use raw PEM
```

---

## Challenge 6: Performance Triage (namespace t6)

### Symptoms
- Requests timing out
- HPA not scaling
- Metrics unavailable

### Root Causes

| # | Issue | Effect |
|---|------|--------|
| 1 | CPU limit too low | Throttling |
| 2 | LimitRange cap | No scaling |
| 3 | No metrics-server | HPA fails |

### Fix Applied
```diff
- cpu: 50m
+ cpu: 500m

- memory: 32Mi
+ memory: 128Mi
```

```bash
kubectl apply -f metrics-server.yaml
kubectl patch deployment metrics-server ...
```

---

## Summary

| Challenge | Root Cause | Fix |
|----------|-----------|-----|
| C1 | Terraform issues | Fix versions/config |
| C2 | Deployment issues | Fix quotas, image, labels |
| C3 | Network policies | Allow traffic + fix DNS |
| C4 | Node failures | Fix kubelet, disk, certs |
| C5 | TLS issues | Fix cert + SAN + CA |
| C6 | Performance | Increase limits + metrics |

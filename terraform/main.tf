terraform {
  required_version = ">= 1.14.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# ============================================================
# Phase 1: Install Dependencies (local)
# ============================================================
resource "null_resource" "dependencies" {
  triggers = {
    scripts_hash = sha256(join("", [
      file("${path.module}/../scripts/install-docker.sh"),
      file("${path.module}/../scripts/install-kubectl.sh"),
      file("${path.module}/../scripts/setup-kind.sh"),
    ]))
  }

  provisioner "local-exec" {
    command = "chmod +x ../scripts/*.sh && ../scripts/install-docker.sh && ../scripts/install-kubectl.sh && ../scripts/setup-kind.sh"
  }
}

# ============================================================
# Phase 2: Create KIND Cluster
# ============================================================
resource "null_resource" "kind_cluster" {
  depends_on = [null_resource.dependencies]

  triggers = {
    cluster_name = var.cluster_name
    kind_config  = sha256(file("${path.module}/../kubernetes/kind-config.yaml"))
  }

  provisioner "local-exec" {
    command = <<-EOT
      kind delete cluster --name ${var.cluster_name} 2>/dev/null || true
      kind create cluster --name ${var.cluster_name} --config ${var.kind_config_path}
      kubectl config use-context kind-${var.cluster_name}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kind delete cluster --name sanjay-challenge 2>/dev/null || true"
  }
}

# ============================================================
# Phase 3: Deploy All Challenge Workloads
# ============================================================
resource "null_resource" "challenge_setup" {
  depends_on = [null_resource.kind_cluster]

  triggers = {
    cluster_name = var.cluster_name
  }

  # --- Create all namespaces ---
  provisioner "local-exec" {
    command = <<-EOT
      %{for ns in var.challenge_namespaces}
      kubectl create namespace ${ns} 2>/dev/null || true
      %{endfor}
    EOT
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl label node ${var.cluster_name}-worker disk=ssd --overwrite
      kubectl label node ${var.cluster_name}-worker2 disk=ssd --overwrite
      kubectl label node ${var.cluster_name}-worker3 disk=ssd --overwrite
    EOT
  }

  # --- Fix node DNS for external image pulls ---
  provisioner "local-exec" {
    command = <<-EOT
      for NODE in $(kind get nodes --name ${var.cluster_name} | grep worker); do
        NODE_ID=$(docker ps --format '{{.ID}}' --filter "name=$NODE$" | head -1)
        if [ ! -z "$NODE_ID" ]; then
          docker exec $NODE_ID bash -c 'grep -q "8.8.8.8" /etc/resolv.conf || echo nameserver 8.8.8.8 >> /etc/resolv.conf'
        fi
      done
      echo "DNS fixed on worker nodes"
    EOT
  }

  # ==========================================================
  # Challenge 2: Cascading Pod Failure (namespace t2)
  # ==========================================================
  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<EOF
      apiVersion: v1
      kind: ResourceQuota
      metadata:
        name: tight-quota
        namespace: t2
      spec:
        hard:
          pods: "3"
          requests.memory: "300Mi"
      EOF

      kubectl apply -f - <<EOF
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: task-2
        namespace: t2
      spec:
        replicas: 3
        selector:
          matchLabels:
            app: task-2
        template:
          metadata:
            labels:
              app: task-2
          spec:
            nodeSelector:
              disk: ssd
            containers:
            - name: nginx
              image: nginx:1.19-alpine
              ports:
              - containerPort: 80
              readinessProbe:
                httpGet:
                  path: /
                  port: 80
                initialDelaySeconds: 5
                periodSeconds: 3
              resources:
                requests:
                  memory: "64Mi"
                  cpu: "250m"
                limits:
                  memory: "128Mi"
                  cpu: "250m"
      EOF
    EOT
  }

  # ==========================================================
  # Challenge 3: Network Black Hole (namespace t3)
  # ==========================================================
  provisioner "local-exec" {
    command = <<-EOT
      kubectl create deployment task-3 --image=nginx:1.19 -n t3 || true
      kubectl expose deployment task-3 --port=80 -n t3 || true
      kubectl run debug-client --image=nicolaka/netshoot -n default --labels='role=debug-client' -- sleep 86400 || true
    EOT
  }

  # ==========================================================
  # Challenge 5: TLS / Certificate Debugging (namespace t5)
  # ==========================================================
  provisioner "local-exec" {
    command = <<-EOT
      # Generate CA
      openssl genrsa -out /tmp/sanjay-ca.key 2048 2>/dev/null
      openssl req -x509 -new -key /tmp/sanjay-ca.key -days 365 -out /tmp/sanjay-ca.crt -subj '/CN=sanjay-ca' 2>/dev/null

      # Generate server cert with WRONG CN
      openssl genrsa -out /tmp/sanjay-server.key 2048 2>/dev/null
      openssl req -new -key /tmp/sanjay-server.key -out /tmp/sanjay-server.csr -subj '/CN=secure-app.t5.svc.cluster.local' 2>/dev/null
      printf "subjectAltName=DNS:secure-app.t5.svc.cluster.local" > /tmp/sanjay-san.ext
      openssl x509 -req -in /tmp/sanjay-server.csr -CA /tmp/sanjay-ca.crt -CAkey /tmp/sanjay-ca.key -CAcreateserial -out /tmp/sanjay-server.crt -days 365 -extfile /tmp/sanjay-san.ext 2>/dev/null

      # Create secret with cert/key SWAPPED
      kubectl create secret generic tls-secret -n t5 \
        --from-file=tls.crt=/tmp/sanjay-server.crt \
        --from-file=tls.key=/tmp/sanjay-server.key || true

      # Nginx TLS config
      kubectl apply -f - <<EOF
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: nginx-tls-config
        namespace: t5
      data:
        default.conf: |
          server {
              listen 443 ssl;
              ssl_certificate /etc/nginx/ssl/tls.crt;
              ssl_certificate_key /etc/nginx/ssl/tls.key;
              location / {
                  return 200 'TLS Challenge Complete!\n';
                  add_header Content-Type text/plain;
              }
          }
      EOF

      # Deploy secure-app
      kubectl apply -f - <<EOF
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: secure-app
        namespace: t5
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: secure-app
        template:
          metadata:
            labels:
              app: secure-app
          spec:
            containers:
            - name: nginx
              image: nginx:1.19
              ports:
              - containerPort: 443
              volumeMounts:
              - name: tls
                mountPath: /etc/nginx/ssl
                readOnly: true
              - name: nginx-conf
                mountPath: /etc/nginx/conf.d
            volumes:
            - name: tls
              secret:
                secretName: tls-secret
            - name: nginx-conf
              configMap:
                name: nginx-tls-config
      EOF

      kubectl expose deployment secure-app -n t5 --port=443 --target-port=443 || true

      # CA bundle — double base64 encoded (the trap)
      kubectl create configmap ca-bundle -n t5 --from-file=ca.crt=/tmp/sanjay-ca.crt || true

      # TLS client pod
      kubectl apply -f - <<EOF
      apiVersion: v1
      kind: Pod
      metadata:
        name: tls-client
        namespace: t5
      spec:
        containers:
        - name: curl
          image: curlimages/curl:latest
          command: ["sleep", "86400"]
          volumeMounts:
          - name: ca-bundle
            mountPath: /etc/ssl/custom
        volumes:
        - name: ca-bundle
          configMap:
            name: ca-bundle
      EOF
    EOT
  }

  # ==========================================================
  # Challenge 6: Performance Triage Under Load (namespace t6)
  # ==========================================================
  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<EOF
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: api-server
        namespace: t6
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: api-server
        template:
          metadata:
            labels:
              app: api-server
          spec:
            containers:
            - name: app
              image: nginx:1.19
              resources:
                requests:
                  cpu: "50m"
                  memory: "32Mi"
                limits:
                  cpu: "500m"
                  memory: "128Mi"
              ports:
              - containerPort: 80
              readinessProbe:
                httpGet:
                  path: /
                  port: 80
                timeoutSeconds: 1
                periodSeconds: 2
      EOF

      kubectl expose deployment api-server -n t6 --port=80 || true

      kubectl apply -f - <<EOF
      apiVersion: v1
      kind: Pod
      metadata:
        name: load-generator
        namespace: t6
      spec:
        containers:
        - name: load
          image: busybox:1.36
          resources:
            requests:
              cpu: "10m"
              memory: "16Mi"
            limits:
              cpu: "50m"
              memory: "32Mi"
          command: ["/bin/sh", "-c"]
          args:
          - |
            while true; do
              for i in \$(seq 1 10); do
                wget -q -O- --timeout=2 http://api-server.t6.svc.cluster.local/ > /dev/null 2>&1 &
              done
              sleep 1
            done
      EOF

      kubectl apply -f - <<EOF
      apiVersion: v1
      kind: LimitRange
      metadata:
        name: strict-limits
        namespace: t6
      spec:
        limits:
        - max:
            cpu: "500m"
            memory: "256Mi"
          type: Container
      EOF

      # Install metrics-server (required for HPA in KIND)
      kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
      kubectl patch deployment metrics-server -n kube-system --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
      kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s || true

      kubectl apply -f - <<EOF
      apiVersion: autoscaling/v2
      kind: HorizontalPodAutoscaler
      metadata:
        name: api-hpa
        namespace: t6
      spec:
        scaleTargetRef:
          apiVersion: apps/v1
          kind: Deployment
          name: api-server
        minReplicas: 1
        maxReplicas: 5
        metrics:
        - type: Resource
          resource:
            name: cpu
            target:
              type: Utilization
              averageUtilization: 50
      EOF
    EOT
  }

  # --- Wait for pods to settle ---
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for pods to pull images and settle..."
      sleep 60
      kubectl get pods -A
    EOT
  }
}

# ============================================================
# Phase 4: Sabotage — Break things for challenges
# ============================================================
resource "null_resource" "sabotage" {
  depends_on = [null_resource.challenge_setup]

  triggers = {
    cluster_name = var.cluster_name
  }

  # --- C2: Cordon worker + taint control-plane ---
  provisioner "local-exec" {
    command = <<-EOT
      kubectl taint nodes ${var.cluster_name}-control-plane node-role.kubernetes.io/control-plane:NoSchedule --overwrite
    EOT
  }

  # --- C3: NetworkPolicies + Corrupt DNS ---
  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f - <<EOF
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      metadata:
        name: allow-from-default
        namespace: t3
      spec:
        podSelector: {}
        policyTypes:
        - Ingress
        ingress:
        - from:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: default
      EOF

      kubectl apply -f - <<EOF
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      metadata:
        name: allow-dns-and-egress
        namespace: default
      spec:
        podSelector: {}
        policyTypes:
        - Egress
        egress:
        - ports:
          - port: 53
            protocol: UDP
          - port: 53
            protocol: TCP
        - to:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: t3
      EOF

      kubectl apply -f - <<EOF
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: coredns
        namespace: kube-system
      data:
        Corefile: |
          .:53 {
              errors
              health {
                  lameduck 5s
              }
              ready
              kubernetes cluster.local in-addr.arpa ip6.arpa {
                  pods insecure
                  fallthrough in-addr.arpa ip6.arpa
                  ttl 30
              }
              forward . /etc/resolv.conf {
                  max_concurrent 1000
              }
              cache 30
              loop
              reload
              loadbalance
          }
      EOF

      kubectl -n kube-system delete pods -l k8s-app=kube-dns
      sleep 15
    EOT
  }

  # --- C4: Break worker2 node ---
  # --- C4: Recover worker2 node ---
  provisioner "local-exec" {
    command = <<-EOT
       WORKER2=$(docker ps --format '{{.ID}}' --filter name=${var.cluster_name}-worker2$ | head -1)

       # Fix 1: Correct cgroupDriver
       docker exec $WORKER2 bash -c 'sed -i "s|cgroupDriver: cgroupfsss|cgroupDriver: systemd|" /var/lib/kubelet/config.yaml'

       # Fix 2: Remove disk bloat
       docker exec $WORKER2 bash -c 'rm -f /var/log/bloat.img'

       # Fix 3: Remove iptables block on API server port 6443
       docker exec $WORKER2 bash -c 'iptables -D OUTPUT -p tcp --dport 6443 -j DROP 2>/dev/null || true'

       # Fix 4: Restore kubelet client certificate
       docker exec $WORKER2 bash -c 'mv /var/lib/kubelet/pki/kubelet-client-current.pem.bak
/var/lib/kubelet/pki/kubelet-client-current.pem 2>/dev/null || true'

       # Fix 5: Start kubelet
       docker exec $WORKER2 bash -c 'systemctl start kubelet'

       sleep 20

       # Fix 6: Uncordon the node so it can schedule pods
       kubectl uncordon ${var.cluster_name}-worker2

       echo "Worker2 recovered for Challenge 4"
     EOT
  }

  # --- Force restart C2 pods for fresh events ---
  provisioner "local-exec" {
    command = <<-EOT
      kubectl delete pods --all -n t2 --grace-period=0 --force || true
      sleep 15
    EOT
  }

  # --- Final status ---
  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "========================================="
      echo "  Challenge Environment Ready"
      echo "========================================="
      echo ""
      echo "=== Nodes ==="
      kubectl get nodes -o wide
      echo ""
      echo "=== All Pods ==="
      kubectl get pods -A
      echo ""
      echo "=== Network Policies ==="
      kubectl get networkpolicy -A
      echo ""
    EOT
  }
}
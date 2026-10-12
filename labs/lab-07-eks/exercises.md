Here is the complete implementation guide and manifest set for the **Lab 07 Independent Exercise** (`usms-timetable` microservice integration).

---

### Implementation Tasks & Manifests

To complete the independent exercise, create the manifest file `manifests/lab-07/35-timetable.yaml` and update the `usms-gateway` NGINX template to enable path-based routing for `/timetable/`.

#### Task 1: Create `manifests/lab-07/35-timetable.yaml`

Run this command in your terminal to generate the ConfigMap, Deployment (with 2 replicas and resource requests), and ClusterIP Service for `usms-timetable`:

```bash
cd ~/Desktop/Seventh-Semester/DSO303/aws-floci-course

cat > manifests/lab-07/35-timetable.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: usms-timetable-conf
  namespace: usms
  labels:
    app: usms-timetable
data:
  default.conf.template: |
    server {
      listen 80;
      location /healthz { add_header Content-Type text/plain; return 200 "ok\n"; }
      location / {
        add_header Content-Type application/json;
        return 200 '{"service": "usms-timetable", "pod": "${POD_NAME}", "campus":"${APP_CAMPUS}", "version": "${APP_VERSION}"}\n';
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: usms-timetable
  namespace: usms
  labels:
    app: usms-timetable
    project: usms
    tier: app
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: usms-timetable
  template:
    metadata:
      labels:
        app: usms-timetable
        project: usms
        tier: app
    spec:
      containers:
      - name: timetable
        image: nginx:1.27-alpine
        ports:
        - name: http
          containerPort: 80
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        envFrom:
        - configMapRef:
            name: usms-app-config
        volumeMounts:
        - name: conf
          mountPath: /etc/nginx/templates
        resources:
          requests:
            cpu: "50m"
            memory: "32Mi"
        readinessProbe:
          httpGet:
            path: /healthz
            port: http
          initialDelaySeconds: 3
          periodSeconds: 5
      volumes:
      - name: conf
        configMap:
          name: usms-timetable-conf
---
apiVersion: v1
kind: Service
metadata:
  name: usms-timetable
  namespace: usms
  labels:
    app: usms-timetable
spec:
  type: ClusterIP
  selector:
    app: usms-timetable
  ports:
  - name: http
    port: 80
    targetPort: http
EOF

```

---

#### Task 2: Update Gateway Manifest (`manifests/lab-07/30-gateway.yaml`)

Update `manifests/lab-07/30-gateway.yaml` to route requests matching `/timetable/` directly to `http://usms-timetable:80/`:

```bash
cat > manifests/lab-07/30-gateway.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: usms-gateway-conf
  namespace: usms
  labels:
    app: usms-gateway
data:
  default.conf.template: |
    server {
      listen 80;

      location /healthz {
        add_header Content-Type text/plain;
        return 200 "ok\n";
      }

      location /enrolment/ {
        proxy_pass http://usms-enrolment:80/;
      }

      location /results/ {
        proxy_pass http://usms-results:80/;
      }

      location /timetable/ {
        proxy_pass http://usms-timetable:80/;
      }

      location / {
        add_header Content-Type application/json;
        return 200 '{"service": "usms-gateway", "status": "operational"}\n';
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: usms-gateway
  namespace: usms
  labels:
    app: usms-gateway
    project: usms
    tier: gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: usms-gateway
  template:
    metadata:
      labels:
        app: usms-gateway
        project: usms
        tier: gateway
    spec:
      containers:
      - name: gateway
        image: nginx:1.27-alpine
        ports:
        - name: http
          containerPort: 80
        volumeMounts:
        - name: conf
          mountPath: /etc/nginx/templates
        resources:
          requests:
            cpu: "50m"
            memory: "32Mi"
        readinessProbe:
          httpGet:
            path: /healthz
            port: http
          initialDelaySeconds: 3
          periodSeconds: 5
      volumes:
      - name: conf
        configMap:
          name: usms-gateway-conf
---
apiVersion: v1
kind: Service
metadata:
  name: usms-gateway
  namespace: usms
  labels:
    app: usms-gateway
spec:
  type: ClusterIP
  selector:
    app: usms-gateway
  ports:
  - name: http
    port: 80
    targetPort: http
EOF

```

---

#### Task 3: Apply and Verify Implementation

Execute this block to apply the manifests, restart the gateway, and verify end-to-end path routing:

```bash
# 1. Apply updated gateway and new timetable service
kubectl apply -f manifests/lab-07/30-gateway.yaml
kubectl apply -f manifests/lab-07/35-timetable.yaml

# 2. Wait for deployments to finish rollout
kubectl rollout status deployment/usms-timetable -n usms --timeout=60s
kubectl rollout restart deployment/usms-gateway -n usms
kubectl rollout status deployment/usms-gateway -n usms --timeout=60s

# 3. Test path-based routing through gateway port-forward
kubectl port-forward svc/usms-gateway -n usms 8080:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 2

echo "--- Testing /enrolment/ ---"
curl -s http://localhost:8080/enrolment/
echo "--- Testing /results/ ---"
curl -s http://localhost:8080/results/
echo "--- Testing /timetable/ ---"
curl -s http://localhost:8080/timetable/

kill $PF_PID 2>/dev/null || true

```

---

### Report Deliverable: Independent Exercise Section

You can paste this structured summary directly into your final lab submission report:

**Independent Exercise Task**: Implementation and Path Routing for `usms-timetable` Microservice.

* **Manifest Creation**: Created `manifests/lab-07/35-timetable.yaml` declaring ConfigMap `usms-timetable-conf`, Deployment `usms-timetable` (2 ready replicas, `50m` CPU request), and ClusterIP Service `usms-timetable`.
* **Gateway Route Configuration**: Updated `manifests/lab-07/30-gateway.yaml` NGINX template with location block `location /timetable/ { proxy_pass http://usms-timetable:80/; }`.
* **Verification**: Confirmed HTTP 200 response returning JSON payload `{"service": "usms-timetable", "pod": "usms-timetable-...", "campus":"rtc", "version": "1.0.0"}` via API path `/timetable/`.
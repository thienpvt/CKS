# 🎯 CKAD Speed-Run — Checklist 14 ngày (dành cho người đã pass CKA)

> **Thông tin đề thi (08/2026):** 15–20 task thực hành · 120 phút · điểm đậu 66% · môi trường Kubernetes v1.35 · được mở đúng 1 tab tài liệu: `kubernetes.io/docs`, `kubernetes.io/blog`, `helm.sh/docs`.
>
> **Nguyên tắc xuyên suốt:** mỗi bài tập bên dưới hãy tự bấm giờ. Mục tiêu ≤ 7 phút/bài. Bài nào quá 8 phút → đánh dấu ⏱ và làm lại vào ngày 11–12. **Không bao giờ gõ YAML từ con số 0** — luôn sinh bằng lệnh imperative hoặc copy từ docs rồi sửa.

---

## 📊 Bảng theo dõi tiến độ

| Ngày | Chủ đề | Xong | Số bài ⏱ phải làm lại |
|------|--------|:----:|:---:|
| 0 | Setup môi trường | ☐ | – |
| 1 | Multi-container patterns | ☐ | |
| 2 | Container images | ☐ | |
| 3 | Ephemeral volumes + drill | ☐ | |
| 4 | Jobs & CronJobs | ☐ | |
| 5 | Probes + Observability | ☐ | |
| 6 | SecurityContext + ServiceAccount | ☐ | |
| 7 | Quota, LimitRange, QoS, CRD | ☐ | |
| 8 | Deployment strategies | ☐ | |
| 9 | Helm + Kustomize | ☐ | |
| 10 | Networking (ôn nhanh) | ☐ | |
| 11–12 | Killercoda + luyện bấm giờ | ☐ | |
| 13–14 | killer.sh + tổng ôn | ☐ | |

---

## Ngày 0 — Setup (≈30 phút)

- [ ] Chuẩn bị cluster luyện tập: `minikube`, `kind`, hoặc killercoda playground (miễn phí, không cần cài gì)
- [ ] Thiết lập alias — **gõ lại từ trí nhớ mỗi sáng cho quen tay**, vì vào phòng thi bạn phải tự gõ:

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"
export now="--force --grace-period=0"
```

- [ ] Cấu hình vim (`~/.vimrc`):

```vim
set expandtab tabstop=2 shiftwidth=2 number autoindent
```

- [ ] Luyện phản xạ `kubectl explain` — thứ thay thế docs nhanh nhất:

```bash
k explain pod.spec.containers.livenessProbe --recursive
k explain cronjob.spec --recursive | less
k explain deploy.spec.strategy
```

- [ ] Tạo tài khoản [killercoda.com](https://killercoda.com/killer-shell-ckad) (scenario CKAD miễn phí)
- [ ] Xác nhận có 2 session [killer.sh](https://killer.sh) đi kèm phí thi (mỗi session mở 36 giờ) — **để dành cho ngày 13**
- [ ] Đọc quy định phòng thi PSI: webcam, phòng trống, ID, remote desktop XFCE

---

## Ngày 1 — Multi-container Pod patterns ⭐ (chủ đề "đặc sản" CKAD)

**Đọc trước (20'):** docs "Pods with multiple containers", "Init Containers", "Sidecar Containers"

- [ ] **Bài 1.1 — Shared emptyDir:** Pod `logger` gồm container `writer` (busybox, mỗi 5s ghi `date` vào `/data/app.log`) và `reader` (busybox, `tail -f /data/app.log`). Cả hai mount chung `emptyDir`. Kiểm chứng: `k logs logger -c reader`
- [ ] **Bài 1.2 — Init container chuẩn bị dữ liệu:** init container busybox ghi `<h1>hello</h1>` vào `/work/index.html` (emptyDir), main container nginx mount emptyDir đó vào `/usr/share/nginx/html`. Kiểm chứng bằng pod tạm: `k run tmp --image=busybox --rm -it --restart=Never -- wget -qO- <pod-ip>`
- [ ] **Bài 1.3 — Native sidecar (kiểu mới, hay ra đề):** sidecar khai báo trong `initContainers` với `restartPolicy: Always` — viết pod nginx kèm sidecar busybox stream log. Hiểu vì sao sidecar kiểu này khởi động *trước* main container và không chặn Job hoàn thành
- [ ] **Bài 1.4 — Adapter:** main container ghi log dạng thô, sidecar đọc và biến đổi format (thêm timestamp/prefix) rồi ghi ra file khác trong volume chung
- [ ] **Bài 1.5 — Init chờ dependency:** init container chạy `until nslookup mydb.default.svc.cluster.local; do sleep 2; done` — tạo Service `mydb` sau, quan sát pod từ `Init:0/1` chuyển sang `Running`
- [ ] **Bài 1.6 — Đọc log đúng container:** với pod nhiều container, luyện `k logs <pod> -c <container>`, `k logs <pod> --all-containers`, `k describe pod` để xem container nào crash

---

## Ngày 2 — Container images (CKA không dạy phần này)

**Đọc trước (15'):** docs Dockerfile reference (ENTRYPOINT vs CMD), quy tắc tag image

- [ ] **Bài 2.1:** Viết Dockerfile: `FROM nginx:alpine`, COPY `index.html` tùy biến, EXPOSE 80. Build: `docker build -t myapp:v1 .` **và** `podman build -t myapp:v1 .` (phòng thi có thể chỉ có podman)
- [ ] **Bài 2.2:** Tag và lưu image ra file:

```bash
docker tag myapp:v1 registry.local:5000/myapp:v1
docker save myapp:v1 -o myapp.tar        # đề hay yêu cầu xuất .tar
docker load -i myapp.tar
podman save/load  # tương tự
```

- [ ] **Bài 2.3 — ENTRYPOINT/CMD ↔ command/args (RẤT hay ra đề):** tạo image có `ENTRYPOINT ["sleep"]`, `CMD ["10"]`. Trong Pod YAML, lần lượt override bằng `command:` (đè ENTRYPOINT) và `args:` (đè CMD). Ghi nhớ bảng quy đổi 4 trường hợp
- [ ] **Bài 2.4 — Private registry:** tạo secret kéo image và gắn vào pod:

```bash
k create secret docker-registry regcred \
  --docker-server=reg.example.com --docker-username=dev \
  --docker-password=pass --docker-email=dev@example.com
# rồi thêm spec.imagePullSecrets vào pod
```

- [ ] **Bài 2.5:** Chạy container trực tiếp để test trước khi đưa vào pod: `docker run --rm myapp:v1`, `docker ps`, `docker logs`

---

## Ngày 3 — Ephemeral volumes + drill tổng hợp

**Đọc trước (15'):** docs Volumes (emptyDir, configMap, secret, downwardAPI, projected)

- [ ] **Bài 3.1:** emptyDir với `medium: Memory` và `sizeLimit: 64Mi` — giải thích được khi nào dùng
- [ ] **Bài 3.2:** Mount ConfigMap dạng volume nhưng **chỉ chọn 1 key** bằng `items:` + đổi tên file bằng `path:`, đặt `defaultMode: 0400`
- [ ] **Bài 3.3:** Cùng một Secret, nạp theo 2 cách trong cùng pod: `envFrom.secretRef` và mount volume — kiểm chứng `k exec ... -- env` và `cat`
- [ ] **Bài 3.4:** downwardAPI volume expose `metadata.labels` và `requests.cpu` của chính pod ra file
- [ ] **Bài 3.5:** projected volume gộp configMap + secret + downwardAPI vào 1 mount point
- [ ] **Drill 30 phút:** làm lại bài 1.1→1.3 và 3.2→3.3 **bấm giờ, không nhìn lại bài giải**

---

## Ngày 4 — Jobs & CronJobs (CKAD hỏi sâu hơn CKA nhiều)

**Đọc trước (15'):** docs Jobs, CronJob. Chạy `k explain job.spec` và `k explain cronjob.spec` đọc hết một lượt

- [ ] **Bài 4.1:** Job in "hello" với `completions: 5`, `parallelism: 2` — quan sát pod chạy theo đợt: `k get pods -w`
- [ ] **Bài 4.2:** Job cố tình fail (`exit 1`) với `backoffLimit: 2` — xem Job chuyển `Failed`, đọc `k describe job` hiểu message
- [ ] **Bài 4.3:** Job `sleep 60` với `activeDeadlineSeconds: 20` — hiểu Job bị kill vì quá hạn, phân biệt với `backoffLimit`
- [ ] **Bài 4.4:** Thêm `ttlSecondsAfterFinished: 30` — Job tự dọn sau khi xong
- [ ] **Bài 4.5:** CronJob mỗi phút chạy `date`. Sinh nhanh:

```bash
k create cj mycron --image=busybox --schedule="*/1 * * * *" $do -- date
```

- [ ] **Bài 4.6:** Trên CronJob, cấu hình đủ bộ: `concurrencyPolicy: Forbid`, `startingDeadlineSeconds: 17`, `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 1`, `suspend: true` rồi bỏ suspend
- [ ] **Bài 4.7 — mẹo cứu điểm:** kích hoạt CronJob chạy ngay không chờ lịch:

```bash
k create job manual-run --from=cronjob/mycron
```

- [ ] Ghi nhớ: pod của Job bắt buộc `restartPolicy: Never` hoặc `OnFailure` (không được `Always`)

---

## Ngày 5 — Probes + Observability

**Đọc trước (15'):** docs "Configure Liveness, Readiness and Startup Probes"

- [ ] **Bài 5.1:** nginx với liveness `httpGet` path `/` port 80, `initialDelaySeconds: 5`, `periodSeconds: 10`
- [ ] **Bài 5.2:** readiness `exec` kiểm tra `cat /tmp/ready` — pod Running nhưng **0/1 Ready**; `k exec` tạo file → thành 1/1. Hiểu rõ: readiness fail = bị rút khỏi Service endpoints, liveness fail = restart container
- [ ] **Bài 5.3:** liveness `tcpSocket` port 3306 trên image mysql/redis
- [ ] **Bài 5.4:** startupProbe cho app khởi động chậm: `failureThreshold: 30` × `periodSeconds: 10` = cho phép tối đa 300s — tự tính được phép nhân này
- [ ] **Bài 5.5 — Drill debug 4 pod hỏng** (tự tạo hoặc nhờ đồng nghiệp/AI tạo manifest lỗi):
  - Image gõ sai tên → `ErrImagePull` — sửa bằng `k set image`
  - Command sai → `CrashLoopBackOff` — đọc `k logs --previous`
  - Request memory quá to → `Pending` — đọc `k describe pod` phần Events
  - Env trỏ ConfigMap không tồn tại → `CreateContainerConfigError`
- [ ] **Bài 5.6:** `k top pod --containers`, `k top node` (cần metrics-server); `k get events --sort-by=.metadata.creationTimestamp`
- [ ] **Bài 5.7 — API deprecation:** cho manifest apiVersion cũ (vd `apps/v1beta1`), tìm version đúng bằng `k api-resources`, `k api-versions`, `k explain <kind>` rồi sửa. Đọc trang "Deprecated API Migration Guide" 10 phút

---

## Ngày 6 — SecurityContext + ServiceAccount

**Đọc trước (15'):** docs "Configure a Security Context", "Configure Service Accounts for Pods"

- [ ] **Bài 6.1:** Pod-level securityContext: `runAsUser: 1000`, `runAsGroup: 3000`, `fsGroup: 2000` — kiểm chứng `k exec ... -- id` và quyền ghi trên volume
- [ ] **Bài 6.2:** Container-level: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true` — app cần ghi `/tmp` thì mount thêm emptyDir vào `/tmp`
- [ ] **Bài 6.3:** `capabilities: {add: ["NET_ADMIN", "SYS_TIME"]}` — nhớ: capabilities chỉ có ở **container-level**, không có ở pod-level
- [ ] **Bài 6.4:** `runAsNonRoot: true` với image chạy root (nginx thường) → pod fail `CreateContainerConfigError`; sửa bằng image `nginxinc/nginx-unprivileged` hoặc set `runAsUser`
- [ ] **Bài 6.5:** Tạo SA và gắn vào pod:

```bash
k create sa build-bot
k run api --image=nginx $do > api.yaml   # thêm spec.serviceAccountName: build-bot
```

- [ ] **Bài 6.6:** `automountServiceAccountToken: false` — kiểm chứng `/var/run/secrets/kubernetes.io/serviceaccount` không còn trong container
- [ ] **Bài 6.7 — RBAC góc nhìn dev (ôn từ CKA, làm nhanh):** Role cho phép `get,list` pods + RoleBinding cho SA trên; kiểm bằng:

```bash
k auth can-i list pods --as=system:serviceaccount:default:build-bot
```

---

## Ngày 7 — ResourceQuota, LimitRange, QoS, CRD

**Đọc trước (15'):** docs Resource Quotas, Limit Ranges

- [ ] **Bài 7.1:** Namespace `dev` với ResourceQuota: `pods: "2"`, `requests.cpu: "1"`, `requests.memory: 1Gi`, `limits.memory: 2Gi`. Tạo pod thứ 3 → đọc hiểu error `exceeded quota`
- [ ] **Bài 7.2:** Lưu ý bẫy: namespace có quota CPU/memory thì pod **bắt buộc khai báo** requests/limits, không là bị từ chối
- [ ] **Bài 7.3:** LimitRange đặt default request/limit cho container — tạo pod *không* khai resources, rồi `k describe pod` xem default được tự gắn
- [ ] **Bài 7.4:** Tạo 3 pod thuộc 3 QoS class (Guaranteed / Burstable / BestEffort), kiểm:

```bash
k get pod -o jsonpath='{.items[*].status.qosClass}'
```

- [ ] **Bài 7.5 — CRD (chỉ cần dùng, không cần viết controller):** apply một CRD đơn giản, tạo custom resource, rồi thao tác:

```bash
k get crd
k api-resources | grep <tên>
k explain <kind> --recursive
k get <kind> -A
```

- [ ] **Bài 7.6:** Hiểu chuỗi Authentication → Authorization → Admission Control ở mức khái niệm (đề chỉ hỏi nhẹ)

---

## Ngày 8 — Deployment strategies (tư duy mới so với CKA)

**Đọc trước (15'):** docs Deployments (phần strategy, rollout)

- [ ] **Bài 8.1 — Rolling update trọn bộ:** deploy nginx 4 replicas, set `maxSurge: 1`, `maxUnavailable: 0`; đổi image → theo dõi:

```bash
k set image deploy/web nginx=nginx:1.25
k rollout status deploy/web
k rollout history deploy/web
k rollout undo deploy/web --to-revision=1
k rollout pause deploy/web && k rollout resume deploy/web
k rollout restart deploy/web
```

- [ ] **Bài 8.2 — Blue/Green thủ công:** 2 Deployment `app-blue` (label `version: blue`) và `app-green` (`version: green`), 1 Service selector `version: blue`. Chuyển traffic bằng cách sửa selector của Service sang `green`. Kiểm bằng pod tạm curl liên tục
- [ ] **Bài 8.3 — Canary thủ công:** `web-v1` 3 replicas + `web-v2` 1 replica, cả hai chung label `app: web`; Service selector `app: web` → ~25% traffic vào v2. Hiểu cách chỉnh tỉ lệ bằng số replica
- [ ] **Bài 8.4:** Scale + HPA:

```bash
k scale deploy web --replicas=6
k autoscale deploy web --min=2 --max=8 --cpu-percent=70
k get hpa
```

- [ ] Phân biệt được `Recreate` vs `RollingUpdate` và khi nào đề bắt dùng Recreate

---

## Ngày 9 — Helm + Kustomize (đã học ở CKA, luyện lại cho nhuyễn)

- [ ] **Helm — làm trọn vòng đời một release:**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo nginx --versions
helm show values bitnami/nginx            # xem value trước khi install
helm install web bitnami/nginx --set replicaCount=2 -n demo --create-namespace
helm list -A
helm upgrade web bitnami/nginx --set replicaCount=3 -n demo
helm history web -n demo
helm rollback web 1 -n demo
helm uninstall web -n demo
helm template web bitnami/nginx           # render không cần cluster
```

- [ ] Biết tìm value trong chart bằng `helm show values ... | grep -i <key>`
- [ ] **Kustomize — dựng cấu trúc base/overlay:**

```
myapp/
├── base/           (deployment.yaml, service.yaml, kustomization.yaml)
└── overlays/
    ├── dev/        (kustomization.yaml: namePrefix dev-, replicas 1)
    └── prod/       (kustomization.yaml: namePrefix prod-, replicas 3, patch image)
```

- [ ] Luyện các transformer hay ra đề: `namePrefix`, `commonLabels`, `images` (đổi tag), `patches`, `configMapGenerator`
- [ ] Chạy: `k kustomize overlays/prod` (xem trước) và `k apply -k overlays/prod`

---

## Ngày 10 — Services / Ingress / Gateway API / NetworkPolicy (thế mạnh CKA — ôn nhanh 1 buổi)

- [ ] Expose đủ kiểu và nắm chắc port vs targetPort vs nodePort:

```bash
k expose deploy web --port=80 --target-port=8080 $do
k expose deploy web --type=NodePort --port=80 $do
```

- [ ] **Bài 10.1:** Ingress 2 path `/api` → svc `api:8080`, `/web` → svc `web:80`. Sinh nhanh:

```bash
k create ingress main --rule="myapp.com/api=api:8080" --rule="myapp.com/web=web:80" $do
```

- [ ] **Bài 10.2:** Ingress + TLS: tạo `k create secret tls` rồi khai `spec.tls`
- [ ] **Bài 10.3:** Gateway API: viết Gateway + HTTPRoute cơ bản (match path, backendRef); biết HTTPRoute chia traffic theo `weight` (cách làm canary hiện đại)
- [ ] **Bài 10.4:** NetworkPolicy 3 bài kinh điển: default-deny-all trong namespace; allow ingress từ pod có label `role: frontend` vào port 6379; allow egress DNS (UDP 53) + tới namespace có label cụ thể. Nhớ: nhiều rule trong `ingress:` là **OR**, các điều kiện trong 1 rule là **AND**
- [ ] **Bài 10.5 — debug quen thuộc từ CKA:** Service không có endpoint → so `k get endpoints` với selector; sửa label

---

## Ngày 11–12 — Killercoda + luyện bấm giờ

- [ ] Làm **toàn bộ** scenario tại [killercoda.com/killer-shell-ckad](https://killercoda.com/killer-shell-ckad), ghi lại thời gian từng bài
- [ ] Làm lại tất cả các bài đã đánh dấu ⏱ trong 10 ngày qua
- [ ] **Mock tự chế:** chọn ngẫu nhiên 8 chủ đề, tự đặt đề, làm trong 50 phút (mô phỏng nhịp 6–7 phút/câu)
- [ ] Luyện thao tác "cứu nguy" khi sửa trường immutable:

```bash
k replace --force -f pod.yaml    # xóa + tạo lại trong 1 lệnh
k delete pod x $now              # xóa không chờ grace period
```

- [ ] Luyện jsonpath tối thiểu: lấy image, tên pod, sort — mỗi thứ 1 lần là đủ

---

## Ngày 13–14 — killer.sh + tổng ôn

- [ ] **Ngày 13:** kích hoạt killer.sh session 1, làm nghiêm túc đủ 120 phút không tra ngoài. **Đề killer.sh khó hơn đề thật rõ rệt — điểm thấp đừng hoảng.** Sau đó dành 2–3 giờ đọc lời giải **từng câu**, kể cả câu làm đúng
- [ ] **Ngày 14 sáng:** làm lại các câu sai của session 1 (môi trường còn mở 36h)
- [ ] **Ngày 14 chiều:** nghỉ. Kiểm tra webcam/ID/phòng thi. Ngủ sớm
- [ ] Session 2 killer.sh: cùng nội dung session 1 — dùng nếu muốn chạy lại toàn bộ, hoặc để dành thi lại

---

## 🧠 Mẹo phòng thi (đúc kết cho người từ CKA sang)

- [ ] **Câu đầu tiên của mỗi task luôn là copy-paste lệnh đổi context** đề cho sẵn (`kubectl config use-context ...`). Sai cluster = 0 điểm dù làm đúng
- [ ] Để ý namespace trong đề — thêm `-n <ns>` vào **mọi** lệnh, hoặc set mặc định: `k config set-context --current --namespace=<ns>`
- [ ] Quét toàn bộ đề trong 2 phút đầu, làm câu dễ/điểm cao trước, flag câu khó. Bỏ qua ngay câu nào kẹt quá 8 phút
- [ ] Đổi thói quen CKA: **ít debug từ tốn, nhiều sản xuất YAML tốc độ.** `$do` + sửa file + apply là vòng lặp chính
- [ ] Ưu tiên `k explain --recursive` thay vì mở docs; chỉ mở docs cho YAML dài (NetworkPolicy, Ingress, PV/PVC, Gateway)
- [ ] Xong mỗi task phải **kiểm chứng**: `k get`, `k describe`, curl bằng pod tạm — đừng tin YAML apply thành công nghĩa là đúng
- [ ] Pod tạm dùng xong tự xóa: `k run tmp --image=busybox --rm -it --restart=Never -- wget -qO- http://svc:80`

---

## 📎 Phụ lục A — Imperative cheat sheet (học thuộc)

```bash
# Pod / Deployment
k run nginx --image=nginx $do > pod.yaml
k run nginx --image=nginx --env=DB=mysql --labels=app=web,tier=fe $do
k create deploy web --image=nginx --replicas=3 --port=80 $do

# Job / CronJob
k create job j1 --image=busybox $do -- /bin/sh -c 'echo hello'
k create cj c1 --image=busybox --schedule="*/5 * * * *" $do -- date
k create job run-now --from=cronjob/c1

# ConfigMap / Secret
k create cm cfg --from-literal=k1=v1 --from-file=app.conf $do
k create secret generic s1 --from-literal=pw=123 $do
k create secret tls web-tls --cert=tls.crt --key=tls.key
k create secret docker-registry regcred --docker-server=... --docker-username=... --docker-password=...

# Service / Ingress
k expose deploy web --port=80 --target-port=8080 $do
k create ingress ing --rule="host.com/path=svc:80" $do

# SA / RBAC
k create sa bot
k create role r1 --verb=get,list --resource=pods
k create rolebinding rb1 --role=r1 --serviceaccount=default:bot
k auth can-i list pods --as=system:serviceaccount:default:bot

# Sửa nhanh không cần mở editor
k set image deploy/web nginx=nginx:1.25
k set env deploy/web DB_HOST=mysql
k set resources deploy/web -c nginx --requests=cpu=100m,memory=128Mi --limits=memory=256Mi
k set sa deploy/web bot
k label pod nginx env=prod ; k annotate pod nginx owner=duc
k scale deploy web --replicas=5
k autoscale deploy web --min=2 --max=8 --cpu-percent=70
```

## 📎 Phụ lục B — Debug nhanh

```bash
k get pods -o wide --show-labels
k describe pod x | tail -20              # Events nằm cuối
k logs x -c app --previous               # log lần crash trước
k get events --sort-by=.metadata.creationTimestamp | tail
k exec -it x -c app -- sh
k top pod --containers
k get deploy web -o yaml > web.yaml      # kéo về sửa rồi replace
k replace --force -f web.yaml
k get pod x -o jsonpath='{.spec.containers[*].image}'
k api-resources --namespaced=true | grep <kind>
```

---

*Chúc bạn thi tốt! Nếu đã pass CKA thì CKAD chủ yếu là trận đấu với đồng hồ — luyện tay nhanh là thắng.* 🏁



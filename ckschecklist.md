# 🛡️ CKS — Checklist theo domain (dành cho người đã pass CKA/CKAD)

> **Thông tin đề thi (đối chiếu lại trước khi đặt lịch):** bài thi performance-based, online proctored, 120 phút, bắt buộc đã pass CKA. Version Kubernetes, pass mark, trọng số domain, allowlist tài liệu, host/SSH workflow và hướng dẫn phòng thi có thể thay đổi.
>
> **Kiểm tra trước khi thi:** trang [LF CKS](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/), [CNCF curriculum](https://github.com/cncf/curriculum) và candidate portal. Không dùng blog cộng đồng khi lệch nguồn chính thức.
>
> **Nguyên tắc xuyên suốt:** mỗi bài tự bấm giờ, mục tiêu **~6–8 phút/bài**, đã trừ thời gian SSH và chờ static pod restart. Quá budget → đánh dấu ⏱, làm lại ở gate của domain. **Không gõ YAML từ con số 0.** Với bài node-level: backup file trước khi sửa, giữ một session SSH thứ hai.

---

## ⚠️ Cảnh báo lab dùng một lần

Các bài dưới đây có **privileged, hostPath, hostPID, hostNetwork, runtime socket, container escape, sửa static pod, xoá RBAC, bật default-deny toàn cluster**. Chỉ chạy trên cluster **disposable** (kubeadm VM có snapshot, hoặc cloud account riêng). Không chạy trên cluster công ty, cluster dùng chung, hay cluster đang ôn thi. Trước mỗi block:

- [ ] Snapshot VM / `etcdctl snapshot save` / biết đường rebuild trong ≤10 phút
- [ ] Có kubeconfig admin **ngoài băng** (file riêng) trước khi áp policy toàn cluster
- [ ] Không gắn cloud credential thật, không VPN công ty, không secret thật trong manifest
- [ ] Xong bài privileged: xoá pod/deployment, xác nhận bằng `k get pods -A | grep -i priv`

---

## 📊 Bảng theo dõi tiến độ

Đo theo **gate**, không theo ngày. Chỉ tick ☑ khi có output chứng minh, không phải "đã đọc" hay "apply thành công".

| Domain | Trọng số | Chủ đề chính | Gate | Xong | Bài ⏱ cần làm lại |
|--------|:--------:|--------------|:----:|:----:|:-----------------:|
| 0 | – | Setup lab, node access, tool offline | ☐ | ☐ | |
| 1 | 15% | Cluster Setup — NetworkPolicy, Ingress TLS, CIS, control-plane/kubelet, binary verify | ☐ | ☐ | |
| 2 | 15% | Cluster Hardening — RBAC least privilege, SA token, anonymous auth, NodeRestriction | ☐ | ☐ | |
| 3 | 10% | System Hardening — seccomp, AppArmor, caps, PSA, host footprint | ☐ | ☐ | |
| 4 | 20% | Minimize Microservice Vulns — securityContext, secrets, encryption at rest, admission, mTLS | ☐ | ☐ | |
| 5 | 20% | Supply Chain — scan, digest, cosign, policy, SBOM, registry | ☐ | ☐ | |
| 6 | 20% | Monitoring/Logging/Runtime — audit, Falco, immutability, incident response | ☐ | ☐ | |
| Goat | – | Attacker/defense phụ trợ (không tính gate) | ☐ | ☐ | |
| Mock | – | 1 đề 120 phút + second pass các bài ⏱ | ☐ | ☐ | |

Trọng số lấy từ CNCF curriculum hiện hành. **System Hardening là domain nhẹ nhất (10%)**, đừng chia đều 6 domain.

**Thứ tự gợi ý (không bắt buộc):** 0 → 3 → 1 → 2 → 4 → 5 → 6. Lý do: kỹ năng node/file của domain 3 và 1 là nền cho audit/encryption/Falco về sau. Mỗi domain vẫn hoàn thành và gate độc lập được.

---

## 🧰 Domain 0 — Setup môi trường (gate, không phải "ngày")

**Lab AWS:** [Ubuntu 26.04, 1 control-plane + 1 worker; setup một lần, snapshot baseline, reset sau mỗi bài](docs/domain0-aws.md). Kết nối qua AWS Console; không dùng `cka-sim bootstrap`.

**Khác gì CKA/CKAD:** CKS sửa **file trên node** (kubelet config, static pod manifest, audit policy, EncryptionConfiguration, Falco rules), không chỉ `kubectl apply`. Vòng `$do + sửa + apply` chỉ là phụ. Cần track riêng "node/file objectives".

- [ ] **Bài 0.1 — Lab đủ mạnh:** kubeadm VM 1 control-plane + 1 worker có snapshot (kind **không** đủ cho node-level: node là container, kube-bench cho kết quả sai cấu trúc, AppArmor/seccomp Localhost cần mount host). Không có VM → dùng Killercoda CKS cho phần cluster-level, ghi rõ phần nào **Blocked**.
- [ ] **Bài 0.2 — Tool offline:** cài sẵn `kubectl`, `crictl`, `etcdctl`, `kube-bench`, `trivy` (pre-pull DB), `cosign`, `kubesec`, `kube-linter`, `helm` + chart Falco/Kyverno, `yq`, `jq`. Thiếu mạng là lý do phổ biến nhất làm drill quá giờ.
- [ ] **Bài 0.3 — Phản xạ kubectl:** luyện lại `$do`, `k explain --recursive`, `k run/create`, `-n` cho mọi lệnh. Đề CKS không thi lại kỹ năng này nhưng chúng là nền để kịp giờ. Lưu ý: base node trong đề **không** có `kubectl`; tool nằm trên host được chỉ định — alias/`export do` phải gõ lại nếu cần, đừng giả định có sẵn.
- [ ] **Bài 0.4 — Node access drill:** ssh vào node, `sudo -i`, rồi:

```bash
ls /etc/kubernetes/manifests/
systemctl status kubelet --no-pager
journalctl -u kubelet -n 50 --no-pager
crictl ps -a
crictl logs <container-id> | tail -20
```

- [ ] **Bài 0.5 — Đối chiếu version:** `kubectl version`, `kubeadm version -o short`. Lab v1.29 thiếu field mới (`appArmorProfile`) — đó là giới hạn lab, không phải bằng chứng field không tồn tại. Cố gắng chạy lab cùng minor với đề.

**Gate:** ssh + `sudo -i` + `crictl ps` chạy được trên node; `kubectl`/`trivy`/`cosign` chạy offline; biết chính xác file nào chứa cấu hình kubelet và apiserver.

---

## 🛡️ Domain 1 — Cluster Setup ⭐ (15%)

**Khác gì CKA/CKAD:** CKA dựng cluster; CKS **siết** cluster có sẵn và **chứng minh** control có hiệu lực. NetworkPolicy phải chứng minh bằng traffic thật, không bằng "apply thành công". CIS benchmark, flag control-plane/kubelet, checksum binary là nội dung mới.

**Đọc trước:** "Network Policies", "Ingress" + TLS, reference `kube-apiserver` (flag list), reference `kubelet` (config), "Declarative Setup"/kubeadm.

**Lab môi trường:** kubeadm VM (không kind) cho kube-bench; CNI có enforce NetworkPolicy (Calico/Cilium, hoặc kind ≥ 0.24 với kindnetd mới).

- [ ] **Bài 1.1 — NetworkPolicy 3 lớp (drill chính):** ns `prod` có `db` (`app=db`, port 6379), `frontend` (`role=frontend`), `attacker` (không label). Dựng default-deny **cả ingress + egress**, allow ingress vào db chỉ từ `role=frontend`:6379, allow egress DNS tới `kube-system`. Kiểm chứng từ trong pod:
  ```bash
  k exec attacker -- nc -zv -w2 db 6379     # timeout
  k exec frontend -- nc -zv -w2 db 6379     # open
  k exec frontend -- nslookup kubernetes.default
  ```
  Nhớ: nhiều rule = **OR**, nhiều điều kiện trong 1 rule = **AND**; thiếu egress DNS thì mọi resolve tên hỏng. `namespaceSelector` dùng label `kubernetes.io/metadata.name`, không dùng tên namespace.
- [ ] **Bài 1.2 — Ingress TLS:** `k create secret tls web-tls --cert=tls.crt --key=tls.key`; Ingress host `web.local` path `/` → svc, thêm `/api` → svc khác. Kiểm:
  ```bash
  k run tmp --rm -it --image=busybox --restart=Never -- \
    wget -qO- --no-check-certificate --header='Host: web.local' https://<ingress-ip>/
  ```
- [ ] **Bài 1.3 — CIS benchmark + remediation loop:** đọc manifest trước khi apply, pin version (fetch-and-run YAML chạy với quyền cluster). Chạy kube-bench trên control-plane node:
  ```bash
  k apply -f kube-bench-job.yaml
  k logs job/kube-bench | grep -E 'FAIL|Summary'
  ```
  Ghi 3 check FAIL, sửa 2 cái, **rerun** và chứng minh check chuyển PASS. Lưu ý: số CIS không map 1:1 với minor Kubernetes.
- [ ] **Bài 1.4 — Apiserver hardening:** backup `/etc/kubernetes/manifests/kube-apiserver.yaml` → `.bak`; xác nhận `--anonymous-auth=false`, `--authorization-mode=Node,RBAC`; chờ static pod restart rồi:
  ```bash
  curl -k https://<apiserver>:6443/api/v1/namespaces/default/pods   # 401/403, không trả list
  ```
- [ ] **Bài 1.5 — Kubelet hardening:** `/var/lib/kubelet/config.yaml` đặt `authentication.anonymous.enabled: false`, `authorization.mode: Webhook`, `readOnlyPort: 0`; `systemctl daemon-reload && systemctl restart kubelet`; `curl -k https://<node>:10250/pods` → 401/403.
- [ ] **Bài 1.6 — Verify platform binary:** tải `kube-apiserver` + `kube-apiserver.sha512` cùng bản release; `sha512sum kube-apiserver` khớp trước khi tin binary.
- [ ] **Bài 1.7 — Metadata endpoint (chỉ trên cloud node):** netpol egress default-deny, không allow `169.254.169.254/32`; `k exec p -- wget -T2 -qO- http://169.254.169.254/` → timeout. Trên kind/kubeadm endpoint không tồn tại → timeout **không** chứng minh gì; đánh dấu cloud-only, không dùng làm gate local.
- [ ] **Bài 1.8 — Dashboard/GUI exposure:** tìm service type `LoadBalancer`/`NodePort` phơi ra ngoài, thu hồi `cluster-admin` của dashboard SA, gán Role chỉ `get/list`; `k auth can-i --list --as=system:serviceaccount:kubernetes-dashboard:kubernetes-dashboard`.
- [ ] **Bài 1.9 — EndpointSlice thay Endpoints:** `k get endpoints` deprecated từ v1.33; kiểm service wiring bằng `k get endpointslice -l kubernetes.io/service-name=<svc>`.

**Drill phá hoại (failure injection):** xoá rule egress DNS khỏi netpol của bài 1.1 → mọi `nslookup` timeout, app không gọi được service. Đo thời gian phát hiện (`k describe netpol`, `k exec -- nslookup`), rồi thêm lại rule, verify. Mục tiêu ≤5 phút từ lúc thấy triệu chứng đến lúc sửa xong.

**Bằng chứng:**
- `k get netpol -n prod -o yaml` + cặp kết quả timeout/open từ trong pod (cross-node nếu được)
- kube-bench summary: PASS/FAIL trước và sau khi sửa
- `sha512sum` khớp file `.sha512`
- `curl` apiserver/kubelet trả 401/403; metadata timeout ≤2s (cloud)

**Gate:**
- [ ] ≤12 phút, từ namespace trống: dựng default-deny + 2 allow (ingress từ frontend, egress DNS)
- [ ] Chứng minh 1 kết nối bị chặn (timeout ≤2s) và 1 được phép (open) — từ **trong** pod
- [ ] Nêu 3 check CIS FAIL + cách sửa, và 1 check đã chuyển PASS
- [ ] `sha512sum` khớp; apiserver/kubelet không credential trả 401/403
- [ ] Thiếu bất kỳ mục nào → chưa đạt

---

## 🔐 Domain 2 — Cluster Hardening (15%)

**Khác gì CKA/CKAD:** CKA tạo Role/RoleBinding; CKS chứng minh **least privilege** và **loại bỏ trust mặc định**: automount token, token ngắn hạn/audience, anonymous auth, NodeRestriction, các verb nguy hiểm (`bind`, `escalate`, `impersonate`).

**Đọc trước:** "Using RBAC Authorization", "Service Accounts", "Managing Service Accounts", reference `kube-apiserver` phần authorization/admission.

**Lab môi trường:** cluster có ≥1 SA thường; một file kubeconfig admin **ngoài băng** để cứu khi tự khoá quyền.

- [ ] **Bài 2.1 — Least privilege:** Role `get/list pods` trong 1 ns + RoleBinding cho SA `build-bot`. Kiểm cả allow lẫn deny:
  ```bash
  k auth can-i list pods -n demo --as=system:serviceaccount:demo:build-bot   # yes
  k auth can-i get secrets -n demo --as=system:serviceaccount:demo:build-bot # no
  k auth can-i list pods -n other --as=system:serviceaccount:demo:build-bot  # no
  ```
- [ ] **Bài 2.2 — Tắt automount:** `k patch sa default -p '{"automountServiceAccountToken":false}'`; tạo pod mới; `k exec ... -- ls /var/run/secrets/kubernetes.io/serviceaccount` → No such file.
- [ ] **Bài 2.3 — Token ngắn hạn + audience:** `k create token build-bot --duration=10m --audience=https://kubernetes.default.svc`; decode payload `cut -d. -f2 | base64 -d`, xác nhận `exp` ~10 phút và `aud` đúng.
- [ ] **Bài 2.4 — Leo thang quyền:** thử tạo Role có verb `escalate`, rolebinding tới `cluster-admin`, hoặc impersonate user khác bằng SA thường → phải bị từ chối. Ghi lại message `forbidden`.
- [ ] **Bài 2.5 — Siết API access:** `--anonymous-auth=false` + `--authorization-mode=Node,RBAC` + `--enable-admission-plugins=NodeRestriction`. Hiểu vì sao NodeRestriction chặn kubelet sửa pod của node khác.
- [ ] **Bài 2.6 — RBAC wildcard audit:** `k auth can-i --list --as=system:serviceaccount:demo:build-bot`; tìm rule `*`/`*`; thu hẹp. Kiểm tra cả `bind`/`escalate` trên roles/clusterroles.
- [ ] **Bài 2.7 — Aggregated ClusterRole:** tạo ClusterRole có `aggregationRule` gom label, verify quyền hợp nhất bằng `auth can-i`.
- [ ] **Bài 2.8 — Upgrade để vá lỗ hổng (recognition):** `kubeadm upgrade plan`, `kubectl version`, `k get nodes -o wide`; nêu quy tắc skew (kubelet không cũ hơn apiserver quá 3 minor với kubelet ≥1.25). Không cần lab upgrade thật.

**Drill phá hoại (failure injection):** tự xoá ClusterRoleBinding admin của user đang dùng → mọi lệnh `forbidden`; phục hồi bằng kubeconfig admin ngoài băng (hoặc apply lại file binding đã backup). Mục tiêu ≤5 phút, và phải chứng minh được **deny** chứ không chỉ allow.

**Bằng chứng:**
- Bảng `k auth can-i` dương/âm: yes với pods trong ns, no với secrets và ns khác
- `ls` trong pod mới không thấy thư mục serviceaccount
- Token decode: `exp` ~10 phút, `aud` đúng
- Manifest apiserver có `anonymous-auth=false` + NodeRestriction; curl không credential trả 401/403
- Message `forbidden` khi thử escalate/bind/impersonate

**Gate:**
- [ ] ≤10 phút: SA chỉ `get/list pods` trong 1 ns
- [ ] Chứng minh cả allow lẫn deny (deny mới là bằng chứng)
- [ ] Pod mới không mount token
- [ ] Anonymous API trả 401/403; thử escalate bị `forbidden`
- [ ] Tự khoá quyền và tự phục hồi được trong ≤5 phút

---

## 🧱 Domain 3 — System Hardening (10%)

**Khác gì CKA/CKAD:** CKA/CKAD dừng ở `securityContext` cơ bản. CKS đi xuống kernel và host: seccomp, AppArmor, capabilities thực tế, PSA, giảm bề mặt host OS. Nhiều bài **không test được trên kind** — ghi rõ.

**Đọc trước:** "Configure a Security Context for a Pod or Container", "Seccomp", "AppArmor" (field `securityContext.appArmorProfile`), "Pod Security Admission", "Linux kernel capabilities".

**Lab môi trường:** kubeadm node để load AppArmor profile và đặt seccomp profile dưới `/var/lib/kubelet/seccomp/`; kind cần `extraMounts` và không dùng được cho bài host OS.

- [ ] **Bài 3.1 — seccomp RuntimeDefault:** pod-level `securityContext.seccompProfile.type: RuntimeDefault`; kiểm `k exec ... -- grep Seccomp /proc/1/status` → `Seccomp: 2`; đổi `Unconfined` → `Seccomp: 0` để thấy khác biệt.
- [ ] **Bài 3.2 — seccomp Localhost:** đặt profile JSON dưới `/var/lib/kubelet/seccomp/profiles/` trên node, trỏ `localhostProfile: profiles/audit.json`; verify bằng `/proc/1/status`. Profile thiếu trên node = pod không start — đó là bài học, không phải lỗi lab.
- [ ] **Bài 3.3 — AppArmor:** `apparmor_parser -r -W /etc/apparmor.d/<profile>`; `aa-status`; pod/container dùng `securityContext.appArmorProfile: {type: Localhost, localhostProfile: <profile>}`; verify bằng `/proc/1/attr/current`. Annotation `container.apparmor.security.beta.kubernetes.io/*` là dạng **legacy** — chỉ nhắc, không dạy làm chính.
- [ ] **Bài 3.4 — PodSecurity Admission:** `k label ns secure pod-security.kubernetes.io/enforce=restricted --overwrite` (thêm `warn`/`audit` và `*-version`); apply pod privileged → bị từ chối trước khi tạo, message `violates PodSecurity "restricted:latest"`; apply pod compliant → vào. So sánh 3 mode trên cùng namespace.
- [ ] **Bài 3.5 — Capabilities:** `drop: ["ALL"]`, `add: ["NET_BIND_SERVICE"]`; `k exec ... -- grep Cap /proc/self/status` hoặc `capsh --print`. Nhớ: capabilities chỉ **container-level**, không có pod-level.
- [ ] **Bài 3.6 — readOnlyRootFilesystem:** bật `true`, mount emptyDir vào `/tmp`; `touch /x` → Read-only file system, `touch /tmp/x` → OK.
- [ ] **Bài 3.7 — Chặn host access:** dưới PSA restricted thử lần lượt `hostPath`, `hostPID`, `hostNetwork`, `privileged`; đọc đúng field bị báo vi phạm. Kết thúc bằng một policy/admission chặn `hostPath` (Kyverno hoặc PSA).
- [ ] **Bài 3.8 — Host OS footprint (không test được trên kind):** `PermitRootLogin no` trong `/etc/ssh/sshd_config`, `systemctl list-unit-files --state=enabled`, `ss -tulpn` liệt kê dịch vụ listen; ghi chú minimal OS / giảm dịch vụ.
- [ ] **Bài 3.9 — Runtime sandbox (recognition):** RuntimeClass gVisor (`runsc`) hoặc Kata; so `uname -r` trong pod sandbox với host.

**Drill phá hoại (failure injection):** trỏ `localhostProfile` tới một profile **không tồn tại** → pod kẹt `CreateContainerConfigError`/runtime error. Chẩn đoán bằng `k describe pod` + `crictl ps -a` + log runtime, sửa về `RuntimeDefault`, verify pod Running và `Seccomp: 2`. Mục tiêu ≤6 phút.

**Bằng chứng:**
- `Seccomp: 2` trong `/proc/1/status`; `Seccomp: 0` khi Unconfined
- `/proc/1/attr/current` hiển thị AppArmor profile
- Message PSA nguyên văn khi pod privileged bị từ chối
- `CapEff` sau drop ALL + add NET_BIND_SERVICE; `touch /x` lỗi read-only, `/tmp` ghi được
- `ss -tulpn`/`systemctl` output cho phần host OS

**Gate:**
- [ ] ≤8 phút: 1 pod pass PSA restricted với seccomp RuntimeDefault, non-root, drop ALL caps, RO rootfs + emptyDir `/tmp`
- [ ] 1 pod privileged bị từ chối, đọc được **lý do** từ message PSA
- [ ] Seccomp/AppArmor verify bằng `/proc`, không đoán từ YAML
- [ ] Chẩn đoán và sửa được pod fail vì profile thiếu

---

## 🧩 Domain 4 — Minimize Microservice Vulnerabilities (20%)

**Khác gì CKA/CKAD:** CKA/CKAD dùng Secret/securityContext ở mức "chạy được". CKS đòi: secret không lộ qua env/proc, **encryption at rest** kiểm bằng etcd raw, admission policy chặn cấu hình xấu, isolation theo microservice, và mã hoá Pod-to-Pod.

**Đọc trước:** "Encrypting Confidential Data at Rest", "Secrets" (good practices), "Pod Security Standards", tài liệu Kyverno (hoặc admission controller đang dùng), "PeerAuthentication" (Istio) / "Cilium Network Policy" nếu dùng.

**Lab môi trường:** quyền đọc `/etc/kubernetes/manifests` + `etcdctl` với cert; **etcd snapshot trước mọi bài encryption**; registry nội bộ cho image unprivileged.

- [ ] **Bài 4.1 — securityContext đầy đủ:** `runAsNonRoot: true`, `runAsUser: 1000`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `drop: ["ALL"]`; verify `k exec ... -- id` = uid 1000. Thử image nginx root → `CreateContainerConfigError`, sửa bằng image unprivileged.
- [ ] **Bài 4.2 — Secret 2 cách:** cùng secret mount file `defaultMode: 0400` và inject env; `k exec -- cat /etc/sec/pw` vs `k exec -- env`; `k exec -- cat /proc/1/environ` cho thấy env lộ trong proc — lý do ưu tiên file mount.
- [ ] **Bài 4.3 — Encryption at rest (drill chính):** snapshot etcd trước. Key: `head -c 32 /dev/urandom | base64`. EncryptionConfiguration `apiVersion: apiserver.config.k8s.io/v1`, provider `aescbc` + `identity` fallback (**aescbc là simplification cho lab**; production dùng `secretbox` hoặc KMS v2 — KMS v1 deprecated/disabled mặc định từ 1.29). Mount file + `--encryption-provider-config`, chờ apiserver restart, tạo secret rồi đọc raw:
  ```bash
  ETCDCTL_API=3 etcdctl --cacert=... --cert=... --key=... get /registry/secrets/default/s1
  # phải thấy prefix k8s:enc:aescbc:v1:
  ```
- [ ] **Bài 4.4 — Rewrite toàn bộ secret + verify:** `k get secrets -A -o json | k replace -f -`; đọc lại raw etcd thấy prefix, không thấy plaintext. Giữ `identity` để đọc dữ liệu cũ; chỉ bỏ key cũ sau khi verify.
- [ ] **Bài 4.5 — Admission policy:** cài Kyverno (pin chart version), ClusterPolicy chặn `privileged` + bắt buộc `runAsNonRoot`/`seccompProfile`; pod vi phạm bị deny (đọc event/message), pod hợp lệ được nhận. Kiểm `failurePolicy`.
- [ ] **Bài 4.6 — Isolation theo microservice:** mỗi service 1 namespace + PSA restricted + default-deny (tái dùng 1.1/3.4) + ResourceQuota; chứng minh service này không gọi được service kia ngoài allow.
- [ ] **Bài 4.7 — Pod-to-Pod encryption:** Cilium WireGuard **hoặc** Istio `PeerAuthentication` mode `STRICT`; verify plaintext từ pod ngoài mesh fail, từ pod trong mesh OK. Tool cụ thể có thể không xuất hiện trong đề — học **control + cách verify**.
- [ ] **Bài 4.8 — RuntimeClass sandbox (tùy chọn):** gVisor/Kata; verify `uname -r` khác host, và policy bắt buộc runtimeClass nếu có.

**Drill phá hoại (failure injection):** tạo secret với key A, sau đó đổi EncryptionConfiguration sang key B **không còn identity** → secret cũ không đọc được (`k get secret` lỗi/decrypt fail). Phục hồi: trả `identity` + key A, restart, verify đọc lại được; nếu hỏng nặng, restore từ etcd snapshot. Bài này dạy đúng rủi ro thật — chỉ làm trên lab có snapshot.

**Bằng chứng:**
- Prefix `k8s:enc:aescbc:v1:` khi đọc raw etcd; grep plaintext secret trong output không thấy
- Kyverno deny message cho pod privileged + pod compliant Running
- `id` trả uid 1000, không phải root
- Secret file mode 0400; env lộ trong `/proc/1/environ`
- mTLS: plaintext ngoài mesh fail, trong mesh OK
- Secret đọc lại được sau khi phục hồi config

**Gate:**
- [ ] ≤15 phút: secret trong etcd đọc raw có prefix `k8s:enc:...`, không thấy plaintext
- [ ] Policy chặn privileged và cho pod compliant qua
- [ ] Pod non-root + no privilege escalation chạy, verify bằng `id`
- [ ] Phục hồi được secret sau khi làm sai EncryptionConfiguration (có snapshot)
- [ ] Chưa verify bằng etcd raw = chưa đạt

---

## 📦 Domain 5 — Supply Chain Security (20%)

**Khác gì CKA/CKAD:** CKA/CKAD chỉ cần image chạy. CKS đòi provenance: scan CVE, pin digest, ký/verify, policy chặn unsigned, SBOM, giới hạn registry, static analysis manifest.

**Đọc trước:** "Image security"/"Verify Signed Container Images", tài liệu Trivy, cosign, Kyverno `verifyImages`, Kubesec/KubeLinter, "Admission Control" (ImagePolicyWebhook).

**Lab môi trường:** registry nội bộ + image đã pull sẵn; Trivy DB pre-download (`--skip-db-update`); cosign keypair throwaway; không commit private key.

- [ ] **Bài 5.1 — Scan image:** `trivy image --severity HIGH,CRITICAL --exit-code 1 nginx:1.27` (offline: `--skip-db-update`). Ghi 1 CVE + fixed version + gate threshold.
- [ ] **Bài 5.2 — Static analysis manifest:** `kubesec scan pod.yaml`; `kube-linter lint .`; hoặc `k apply --dry-run=server` vào ns restricted để bắt vi phạm trước deploy.
- [ ] **Bài 5.3 — Pin theo digest:** `crane digest nginx:1.27` hoặc `docker buildx imagetools inspect`; deploy `image: nginx@sha256:...`; verify `k get pod -o jsonpath='{.spec.containers[0].image}'` chứa `@sha256:`, không phải tag.
- [ ] **Bài 5.4 — Ký/verify:** `cosign generate-key-pair`; `cosign sign --key cosign.key <registry>/app@sha256:...`; `cosign verify --key cosign.pub ...` pass; verify image khác hoặc key khác → fail. Keyless cần OIDC — lab offline dùng keypair.
- [ ] **Bài 5.5 — Policy chặn unsigned:** Kyverno ClusterPolicy `verifyImages` với attestor public key; apply pod image unsigned → deny; image đã ký → admit. Kiểm `failurePolicy: Fail` và webhook có trong `k get validatingwebhookconfiguration`.
- [ ] **Bài 5.6 — ImagePolicyWebhook (recognition + drill nhỏ):** AdmissionConfiguration + kubeconfig trỏ webhook; thêm `--enable-admission-plugins=NodeRestriction,ImagePolicyWebhook` + `--admission-control-config-file`; `defaultAllow: false` chứng minh chặn mọi image, rồi allowlist 1 image.
- [ ] **Bài 5.7 — Giới hạn registry:** netpol egress chỉ allow registry IP:443; `k exec -- wget -T2 https://registry.k8s.io` timeout, registry nội bộ OK. Hoặc admission policy chỉ cho registry đã duyệt.
- [ ] **Bài 5.8 — SBOM:** `trivy image --format spdx-json -o sbom.json nginx:1.27`; đếm package, tìm 1 package có CVE trong SBOM.
- [ ] **Bài 5.9 — Private registry:** `k create secret docker-registry regcred ...` + `imagePullSecrets`; verify pod pull được, và pod không có secret thì `ErrImagePull`.
- [ ] **Bài 5.10 — Dockerfile baseline (recognition):** base tối giản, non-root USER, không secret trong layer, multi-stage; liên hệ vì sao ít package = ít CVE.

**Drill phá hoại (failure injection):** ký image bằng key A nhưng policy chỉ trust key B → `cosign verify` fail và pod bị deny. Sửa theo 2 hướng (ký lại bằng B, hoặc cập nhật public key trong policy), verify pod được admit. Mục tiêu ≤8 phút.

**Bằng chứng:**
- Bảng trivy: số CRITICAL/HIGH + 1 CVE kèm fixed version
- Pod spec chứa `@sha256:` thay vì tag
- `cosign verify` pass cho image ký, fail cho image không ký/key sai
- Kyverno deny message cho image unsigned; pod image ký được admit
- `sbom.json` tồn tại, đếm được package
- `imagePullSecrets` hoạt động

**Gate:**
- [ ] ≤15 phút: scan 1 image ra CVE + fixed version
- [ ] Deploy bằng digest, verify qua jsonpath thấy `@sha256:`
- [ ] Ký và verify 1 image; verify 1 image không ký fail
- [ ] Policy chặn được image unsigned và admit image đã ký
- [ ] Nêu 1 CVE cụ thể + cách vá

---

## 📊 Domain 6 — Monitoring, Logging and Runtime Security (20%)

**Khác gì CKA/CKAD:** hoàn toàn mới ở mức vận hành: audit log của apiserver, phát hiện hành vi runtime (Falco/Tetragon), immutability, và **incident response** — điều tra, cô lập, thu bằng chứng.

**Đọc trước:** "Auditing" (audit.k8s.io/v1, levels, omitStages), reference `kube-apiserver` (audit flags), Falco docs (rules, condition/output/priority), "Runtime Class"/immutability.

**Lab môi trường:** VM có kernel headers/BTF cho Falco (WSL2/kind hay fail eBPF — ghi Blocked, không tắt cơ chế bảo mật kernel); audit path là `hostPath` với giới hạn dung lượng.

- [ ] **Bài 6.1 — Audit policy:** viết `audit.k8s.io/v1` policy `level: Metadata` cho secrets, `RequestResponse` cho `pods/exec`, `None` cho noisy read; mount file + `--audit-policy-file` + `--audit-log-path=/var/log/kubernetes/audit.log` + `--audit-log-maxsize/maxbackup/maxage`. Chỉ `audit.k8s.io/v1` tồn tại (v1beta1/v1alpha1 đã bị bỏ từ 1.24).
- [ ] **Bài 6.2 — Sinh và tìm event:** `k get secret s1`, `k exec -it p -- sh`, tạo pod; rồi:
  ```bash
  grep '"resource":"secrets"' /var/log/kubernetes/audit.log | tail -1 | jq '.verb,.user.username,.objectRef'
  ```
  Phải thấy `verb: get`, user cụ thể, objectRef đúng.
- [ ] **Bài 6.3 — Audit chứng minh identity:** tạo user bằng CSR/client cert, thao tác, rồi tìm `user.username` = CN trong audit log. (Ghép với Domain 2.) Giải thích 3 mức audit và lý do chọn.
- [ ] **Bài 6.4 — Falco:** cài từ chart đã pin/preinstall; `k exec -it nginx -- sh`; `k logs -n falco -l app.kubernetes.io/name=falco -c falco | grep -i 'Terminal shell in container'` — ghi rule name + output field.
- [ ] **Bài 6.5 — Custom Falco rule:** rule bắt đọc `/etc/shadow` hoặc ghi `/usr/bin`; nạp qua ConfigMap/`-r`/helm values; reload; trigger và thấy alert mới. Hiểu `condition`, `output`, `priority`.
- [ ] **Bài 6.6 — Immutability:** `readOnlyRootFilesystem: true` + `emptyDir` cho path cần ghi; Falco phát hiện nỗ lực ghi/exec; digest pin để container không bị thay. Đây là objective riêng, không chỉ là bài 3.6.
- [ ] **Bài 6.7 — Incident response:** pod bị compromise giả lập (privileged/hostPath, chạy shell). Trình tự: `k cordon <node>`, quarantine NetworkPolicy (deny-all + allow-only-forensics), `k logs --previous`, `crictl ps/logs`, chụp `imageID` + process tree, **rồi mới** xoá pod. Chứng minh traffic bị chặn và bằng chứng đã lưu.
- [ ] **Bài 6.8 — Kill chain:** dựng chuỗi initial access (exec) → persistence (tạo SA/token) → exfiltration (egress bị netpol chặn), rồi ghép **audit + Falco + events** để kể lại từng bước. Đề CKS không chia silo domain.
- [ ] **Bài 6.9 — Quan sát nhanh:** `k top pod --containers`, `k get events --sort-by=.metadata.creationTimestamp`, `k get events --field-selector type=Warning`, `k logs --previous`.

**Drill phá hoại (failure injection):** đổi audit policy mức `None` (hoặc sai `--audit-log-path`) → thao tác nhưng log không có entry. Chẩn đoán bằng `crictl logs` của apiserver container + kiểm flag trong manifest, sửa, restart, verify entry xuất hiện. Mục tiêu ≤8 phút. (Biến thể: stop Falco → không alert, restart và verify.)

**Bằng chứng:**
- Dòng Falco chứa rule name + output + pod/ns khi exec shell
- Audit log có entry JSON `get secrets` với `user.username` cụ thể
- AuditPolicy thể hiện đúng các mức (None/Metadata/Request/RequestResponse)
- Falco alert cho custom rule
- Bằng chứng incident: log, imageID, process tree, netpol quarantine + timeout

**Gate:**
- [ ] ≤12 phút: exec shell → Falco alert ≤60s với rule name
- [ ] Audit log chứa entry get secrets + exec với user cụ thể (grep ra được)
- [ ] Giải thích 3 mức audit và lý do chọn
- [ ] 1 custom rule bắt được hành vi
- [ ] Incident drill: cordon + quarantine + thu bằng chứng trước khi xoá
- [ ] Thiếu audit log thực tế = chưa đạt

---

## 🐐 Kubernetes Goat — phụ trợ, không phải đề thi

Goat là sandbox tấn công/phòng thủ, **không** mô phỏng đề CKS và **không** tính vào gate domain. Dùng để thấy góc nhìn attacker rồi quay lại siết cấu hình. Pin commit/tag, cluster disposable, không cloud credential, không VPN công ty, rebuild sau mỗi block. Timebox 2–3h.

| Scenario | Domain map | Việc làm |
|---|---|---|
| RBAC least privilege / cluster-admin | 2 | Leo thang bằng SA yếu → viết Role đúng → chứng minh `auth can-i` deny |
| NetworkPolicy bypass | 1 | Gọi service bị chặn → thêm default-deny + allow → chứng minh timeout |
| Secret trong image / env | 4 | Trích secret từ image layer/proc → chuyển sang file mount + encryption at rest |
| Container escape / hostPath / DIND | 6 (+3) | Chạy exploit → đọc audit/Falco → áp PSA restricted + policy chặn hostPath |
| Sensitive keys in codebase (tùy chọn) | 5 | Scan repo/image → thêm gate scan + policy |

Bỏ qua scenario dùng Helm v2/Tiller (deprecated) và scenario không map domain. Vòng lặp: **exploit → ghi bằng chứng → sửa config → chạy lại exploit → xác nhận bị chặn**.

---

## 🏁 Luyện đề & tổng ôn (không gắn ngày)

- [ ] **Killercoda CKS:** làm theo domain, ghi scenario → bài nào tương ứng; dùng để **kiểm tra gate**, không học thêm lý thuyết.
- [ ] **killer.sh CKS:** 2 session, mỗi session mở 36h. Làm nghiêm túc 120 phút, rồi đọc lời giải **từng câu** kể cả câu đúng. Đề khó hơn đề thật — điểm thấp không phản ánh năng lực, điểm cao không phải bằng chứng sẵn sàng.
- [ ] **Mock tự chế 120 phút:** chọn 5–6 bài ngẫu nhiên từ ≥4 domain khác nhau, không nhìn bài giải. Mục tiêu ≤10 phút/bài, tổng ≤90 phút để dư thời gian verify.
- [ ] **Second pass:** chạy lại mọi bài ⏱ + 1 mock. Chỉ khi tất cả gate đã ☑ mới đặt lịch thi.
- [ ] **Offline dress rehearsal:** tắt mạng, chạy 1 drill có scan/ký/Falco để chắc tool + DB + chart đã có sẵn.

---

## 📚 Ưu tiên nguồn

- **P0:** trang LF CKS (version, weight, allowlist, hướng dẫn thi) · CNCF `CKS_Curriculum v1.37.pdf` · `kubernetes.io/docs` mục Security/Policies/Tasks.
- **P1:** Killercoda CKS · killer.sh CKS.
- **P2:** Kubernetes Goat (chỉ scenario đã map) · docs chính thức Falco/Trivy/cosign/Kyverno/Cilium/Istio.
- **P3:** blog — chỉ dùng khi ghi rõ version và khớp curriculum; bỏ qua nếu lệch.

Không dùng kube-hunter (không còn phát triển; dùng Trivy cho cluster/kube-bench cho CIS). Không dùng chart Bitnami cũ (`bitnamilegacy` không còn vá bảo mật) — chọn chart khác hoặc pin bản còn hỗ trợ.

---

## 🧭 Quy trình trong phòng thi

1. Đọc task → ghi ra **host đích + context/namespace + đường dẫn file** trước khi gõ lệnh.
2. `ssh <host>` (không nested ssh), `sudo -i` nếu cần sửa file hệ thống.
3. Chỉ thao tác trên host/node task chỉ định. Sửa node khác có thể phá task khác.
4. Sửa static pod/config: backup `.bak`, sửa từng thay đổi, chờ restart, verify (`crictl ps`, `journalctl`), revert ngay nếu không healthy.
5. Verify bằng output thật (`k get`, `curl`, `crictl`, grep log) — "apply thành công" không phải bằng chứng.
6. Trả về base node sau mỗi task. Không dùng script ngoài phạm vi task.

---

## 🧠 Mẹo phòng thi

- [ ] Task đầu tiên luôn xác định **host** và **context**, không chỉ `kubectl config use-context`. Sai host = 0 điểm dù cấu hình đúng.
- [ ] Thêm `-n <ns>` vào **mọi** lệnh, hoặc set mặc định context namespace.
- [ ] Quét toàn bộ đề 2 phút đầu, làm câu chắc điểm trước; bỏ qua câu kẹt quá 8 phút.
- [ ] CKS là **điều tra + hardening**, không phải đua gõ YAML. Đọc `k describe`, `events`, log trước khi sửa.
- [ ] Docs chỉ mở được một số trang; học trước cấu trúc URL của NetworkPolicy, Audit, EncryptionConfiguration, PSA — đừng dựa vào `k explain` cho field mới.
- [ ] Kiểm tra admission trước khi đổ lỗi workload: PSA label namespace, webhook policy, `failurePolicy`.
- [ ] Phân biệt `runAsNonRoot` (chặn root) vs `runAsUser` (ép uid); PSA label vs namespace label; audit level vs omitStages.
- [ ] Pod tạm dùng xong tự xoá: `k run tmp --image=busybox --rm -it --restart=Never -- ...`.
- [ ] Không dùng `kubectl replace --force`/`delete` cho static pod — đó là **file**, không phải object; xoá nhầm có thể mất apiserver.

---

## 📎 Phụ lục A — Cheat sheet CKS (học thuộc)

```bash
# PSA / Admission
k label ns secure pod-security.kubernetes.io/enforce=restricted --overwrite
k label ns secure pod-security.kubernetes.io/enforce-version=latest --overwrite
k label ns secure pod-security.kubernetes.io/warn=restricted --overwrite
k get ns secure -o jsonpath='{.metadata.labels}'

# RBAC — least privilege
k create role r1 --verb=get,list --resource=pods -n demo
k create rolebinding rb1 --role=r1 --serviceaccount=demo:bot -n demo
k auth can-i --list --as=system:serviceaccount:demo:bot
k auth can-i get secrets -n demo --as=system:serviceaccount:demo:bot
k create token bot --duration=10m --audience=https://kubernetes.default.svc -n demo

# NetworkPolicy + DNS + EndpointSlice
k get netpol -A
k describe netpol deny-all -n prod
k get endpointslice -l kubernetes.io/service-name=<svc>
k exec p -- nslookup kubernetes.default
k exec p -- nc -zv -w2 db 6379

# Secret / encryption at rest
k create secret generic s1 --from-literal=pw=dev-only
k create secret tls web-tls --cert=tls.crt --key=tls.key
k create secret docker-registry regcred --docker-server=... --docker-username=... --docker-password=...
head -c 32 /dev/urandom | base64
ETCDCTL_API=3 etcdctl --cacert=... --cert=... --key=... get /registry/secrets/default/s1
k get secrets -A -o json | k replace -f -

# Control plane / kubelet / audit
grep -E 'anonymous-auth|authorization-mode|enable-admission-plugins|audit-' /etc/kubernetes/manifests/kube-apiserver.yaml
systemctl daemon-reload && systemctl restart kubelet
journalctl -u kubelet -n 50 --no-pager
crictl ps -a ; crictl logs <id>
grep '"resource":"secrets"' /var/log/kubernetes/audit.log | tail -1 | jq '.verb,.user.username'

# CIS / binary
kube-bench --targets controlplane   # hoặc job YAML đã pin
sha512sum kube-apiserver             # so với .sha512 cùng release

# Image supply chain
trivy image --severity HIGH,CRITICAL --exit-code 1 --skip-db-update nginx:1.27
trivy image --format spdx-json -o sbom.json nginx:1.27
crane digest nginx:1.27
cosign sign --key cosign.key <registry>/app@sha256:...
cosign verify --key cosign.pub <registry>/app@sha256:...
kubesec scan pod.yaml ; kube-linter lint .

# AppArmor / seccomp
apparmor_parser -r -W /etc/apparmor.d/<profile> ; aa-status
ls /var/lib/kubelet/seccomp/profiles/
k exec p -- grep Seccomp /proc/1/status
k exec p -- cat /proc/1/attr/current
k exec p -- grep Cap /proc/self/status
```

## 📎 Phụ lục B — Debug nhanh & phục hồi

```bash
# Static pod / control plane không lên sau khi sửa flag
crictl ps -a | grep -E 'kube-apiserver|etcd'
crictl logs <id> 2>&1 | tail -40
ls -l /etc/kubernetes/manifests/*.bak
cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
# kubelet
systemctl status kubelet --no-pager ; journalctl -u kubelet -n 80 --no-pager
# Cluster không phản hồi sau default-deny
k get netpol -A ; k delete netpol <ten> -n <ns>     # lệnh cứu
# Secret không đọc được sau encryption
k get secret s1 -n default -o yaml
grep -E 'encryption-provider-config' /etc/kubernetes/manifests/kube-apiserver.yaml
# Container không start vì seccomp/AppArmor
k describe pod p | grep -A5 Events
crictl ps -a ; crictl logs <id> 2>&1 | tail
# Audit không có entry
crictl logs <apiserver-id> 2>&1 | grep -i audit
grep -E 'audit-policy-file|audit-log-path|audit-log-max' /etc/kubernetes/manifests/kube-apiserver.yaml
# Falco không alert
k logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=100
k get pods -n falco -o wide          # driver/ebpf có lên?
# Workload / node
k get events --field-selector type=Warning --sort-by=.metadata.creationTimestamp
k get pods -o wide --show-labels
k logs p --previous
k get pod p -o jsonpath='{.status.containerStatuses[0].imageID}'
crictl inspect <id> | jq '.info.runtimeSpec.process'
```

---

## ✅ Checklist cuối trước khi thi

- [ ] Cả 6 gate domain đã ☑ với bằng chứng output, không phải "đã đọc"
- [ ] Mọi bài ⏱ đã làm lại và qua budget
- [ ] 1 mock 120 phút hoàn chỉnh, tự chấm theo gate
- [ ] Verify được: netpol deny+allow, PSA deny, etcd prefix `k8s:enc:`, cosign verify, audit entry, Falco alert
- [ ] Backup/rollback path cho từng loại mutation (manifest `.bak`, etcd snapshot, admin kubeconfig ngoài băng)
- [ ] Tool offline đã kiểm tra: trivy DB, cosign, kube-bench, chart Falco
- [ ] Đã đối chiếu LF CKS: version, weight, allowlist, prerequisite

---

*CKS không phải cuộc đua gõ YAML — nó là chứng minh bằng output rằng từng lớp kiểm soát thực sự có hiệu lực.* 🛡️

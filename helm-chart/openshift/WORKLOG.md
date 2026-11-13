# OpenShift deployment work log

## 2026-11-13

- Audited the initial checkout and selected the explicitly requested `v2.24.0` tag.
- Created branch `codex/openshift-v2.24.0` from `v2.24.0`.
- Per the user's direction, discarded the pre-existing edits to `helm-chart/values.yaml` and `helm-chart/templates/cvat_kvrocks/statefulset.yml`, and removed the identified untracked diagnostic/render files (`1.txt`, `cvat-diagnostics-20261102-232445.txt`, `cvat-diagnostics.ps1`, `rendered.yaml`).
- Added `helm-chart/openshift-v2.24.yaml` with release-pinned CVAT images, disabled the `chmod -R 777` permission-fix init container, selected RWX/RWO PVC claim modes, disabled optional analytics, and let OpenShift assign workload identities.
- Added an OpenShift-specific UI image build because upstream nginx listens on port 80; the derived image listens on 8080 and writes PID/temp files under `/tmp`.
- Added a standalone Redis StatefulSet and service. The v2.24.0 PostgreSQL and Redis subcharts include Bitnami `common` libraries with conflicting global helper names; rendering both together fails. The override disables the Redis subchart and points CVAT to this Redis service.
- Added an OpenShift Route with an auto-assigned host. The derived frontend proxies CVAT backend paths internally so only one Route is needed; also added install/upgrade and troubleshooting instructions.
- Rebuilt the ignored local Helm dependency cache from the v2.24.0 `Chart.yaml` so it no longer contains packages from the newer branch.

### Validation so far

- Helm v4.3.1 `helm lint` with the OpenShift override: passed.
- Helm v4.3.1 `helm template` with the OpenShift override: passed.
- Render inspection: CVAT server image is `cvat/server:v2.24.0`; PostgreSQL uses the CVAT public ECR mirror at the chart's PostgreSQL 15.2 tag; custom frontend image is `cvat/ui-openshift:v2.24.0`; RWX backend claim is rendered; no `runAsUser`, `fsGroup`, PostgreSQL volume-permission job, or CVAT chmod permission-fix container is rendered.
- At the initial audit stage, install and runtime validation were pending. The restricted workspace shell could not resolve `api.rm3.7wse.p1.openshiftapps.com`; authenticated cluster operations succeeded through an elevated PowerShell-backed shell as `tamirk-crt`.

### Live cluster information supplied/observed after the initial audit

- The authenticated identity is `tamirk-crt`, and the active project is `tamirk-crt-dev`.
- A subsequent full inventory found the previous `cvat-release-tamir` release and its workloads, alongside existing PVCs and namespace resources.
- `tamirk-crt` cannot create projects or namespaces, but can create Deployments, PVCs, and Routes in `tamirk-crt-dev`.
- Storage classes include `efs-sc` (EFS CSI, RWX-capable) and default `gp3` (EBS CSI, RWO). `efs-sc` uses EFS access points, a UID/GID range of 1000–2000, and root-directory permissions 0700. EFS access-point identity enforcement maps client file operations to the access-point identity. A reversible in-pod write check passed. [EFS CSI parameters](https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/docs/parameters.md)
- The identity range for `tamirk-crt-dev` is `1005980000/10000`, including the supplemental-group range.
- The account cannot read the cluster ingress config to discover the apps domain. The Route manifest now leaves `spec.host` unset so OpenShift assigns one automatically.
- `tamirk-crt` can create BuildConfigs and ImageStreams in `tamirk-crt-dev`; an OpenShift binary build is documented for the derived UI image to avoid requiring workstation Docker.
- The user's PowerShell can query the API, while the workspace shell initially failed DNS; API queries succeeded when run outside the restricted network sandbox.
- The user chose the existing shared project `tamirk-crt-dev` instead of a new project and authorized deleting all workloads there. At cleanup time, removed 13 Deployments (12 old CVAT/Grafana/OPA + `test1`) and 5 StatefulSets (ClickHouse, Kvrocks, PostgreSQL, Redis, Vector). PVCs, Services, ConfigMaps, Secrets, and the old Helm release metadata were preserved.
- The restricted-compatible CVAT UI image build completed successfully in the project and was pushed to the internal ImageStream `cvat-ui-openshift:v2.24.0`.
- Project storage quota is 80Gi with 44Gi already requested by preserved PVCs. The new backend/DB/Kvrocks/Redis claims are sized to 35Gi total so requested storage stays within quota.
- Helm lint/render passed, and the first install created the backend EFS PVC (Bound, 20Gi RWX), PostgreSQL PVC (Bound), Kvrocks PVC (Bound), Redis PVC (Bound), PostgreSQL pod (Ready), Redis pod (Ready), and frontend pod (Ready). The user-approved Route `cvat` was created with an OpenShift-assigned host.
- Runtime exposed two restricted-v2 image-layer permission problems: the fixed upstream server image's `/home/django` traversal permissions blocked the SCC UID; upstream Kvrocks could not create its PID file in `/var/lib/kvrocks`. Added derived `backend.Dockerfile` and `kvrocks.Dockerfile`, changed the overlay to internal project ImageStreams, and built both images successfully. The build runs also demonstrated successful internal registry pushes.
- Initial install/upgrade revisions 1–4 failed while successive permission issues were diagnosed; PVCs were preserved throughout. Revisions 5–7 are now deployed successfully after the successive fixes.
- Read-only request to the assigned Route returned HTTP 200 and the CVAT page title; this confirms frontend delivery only, not API/backend readiness or authentication.
- The first derived backend image fixed entrypoint access and allowed every backend worker to start. The server then needed `/home/django/static` write access for `collectstatic`; the second backend image adds sticky write permission there.
- The initializer Job was missing all backend volume mounts in the upstream chart. Its logs showed that generating `keys/secret_key.py` failed against the image layer. A reversible write check from a backend pod succeeded on the EFS PVC (access-point files are owned by UID/GID 1056, mapped by the EFS access point), so the remaining issue is the initializer's missing PVC mount, not a cluster storage permission change. The overlay now mounts the `keys` subPath into the initializer so it can persist and share the generated secret key.
- Official Apache Kvrocks v2.7 Dockerfile config points its PID file to `/var/run/kvrocks/kvrocks.pid`; the first image only made `/var/lib/kvrocks` writable. A second derived image and overlay tag now make `/var/run/kvrocks` writable as well.
- The PID fix allowed Kvrocks to start, then exposed its startup rewrite of `/var/lib/kvrocks/kvrocks.conf` failing on a sticky directory. The third derived image sets the application config directory to mode 0777 while retaining sticky mode for `/var/run/kvrocks` and `/tmp`. The Kvrocks pod is now Ready with the `v2.7.0-r3` image, and its RWO PVC is Bound.
- The current overlay mounts the backend PVC's `data`, `keys`, `logs`, and `models` subpaths into the initializer; this allowed migrations and key generation to complete.

### Final acceptance verification

- Helm release `cvat`, revision 7: `deployed`, description `Upgrade complete`.
- All 11 Deployments are Available, including backend server, all worker types, frontend, and OPA. PostgreSQL, Redis, and Kvrocks StatefulSets are each 1/1 Ready. Initializer Job `cvat-backend-initializer-r7` completed 1/1. All four application PVCs are Bound (backend 20Gi RWX EFS; PostgreSQL 8Gi, Kvrocks 5Gi, Redis 2Gi RWO gp3).
- OpenShift Route: `https://cvat-tamirk-crt-dev.apps.rm3.7wse.p1.openshiftapps.com/`. Frontend page returned HTTP 200 and the CVAT title. `/api/server/about` returned HTTP 200 with version `2.24.0`.
- Created test superuser `cvat-admin`; authenticated `GET /api/users/self` returned HTTP 200 and the expected administrator identity.
- Created project `openshift-v224-validation` (ID 1), task `openshift-v224-image-task` (ID 1), uploaded repository sample `tests/mounted_file_share/images/image_1.jpg` (8,072 bytes), and confirmed task size 1 with a single job. Saved a rectangle annotation on frame 0 via the Job annotations API and read it back (HTTP 200; one shape, label ID 1, points `[50,50,300,300]`).
- Route API checks and the in-pod EFS write check passed after revision 7. The successive event checks found that chunks, analytics reports, quality reports, and webhooks worker templates lacked shared `keys`, `data`, and `logs` PVC mounts. The overlay adds these mounts; all affected workers are now Ready with zero restarts and no new liveness warnings after the revision 7 rollout.
- Revision 7 is deployed with all 11 Deployments and 3 StatefulSets Ready. A project quota limited ReplicaSets to 30; 22 inactive zero-replica CVAT ReplicaSets were removed (no pods/PVCs), freeing room for the changed workers. Current resource requests remain within namespace quotas.
- The legacy `cvat-release-tamir` still has preserved Pending PVCs and generated a storage provisioner warning because its requested volume capability is unsupported by `gp3`. These PVCs were not modified or deleted; they are not used by the new `cvat` release.
- After revision 7, re-read through the Route confirmed version `2.24.0`, authenticated superuser identity, project/task/image metadata, and the saved rectangle annotation are still present. All refreshed worker pods remain Ready with zero restarts, and no new worker liveness warnings appeared after that rollout.
- `POST /api/auth/login` with the test account returned HTTP 200 and issued an authentication token; token value was not logged. The route root and `/api/server/about` also respond successfully.
- Representative application pods were admitted by `restricted-v2` with UID `1005980000`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, and all capabilities dropped. The container primary GID remains 0 in these upstream images; no root UID or privileged SCC was used.

# CVAT 2.24.0 on OpenShift

This deployment uses the upstream `v2.24.0` Helm chart and a separate restricted-v2 values overlay. The chart's `dev` branch and local edits are not used. The overlay, UI image and two additional restricted-v2 image builds have been prepared in `tamirk-crt-dev`; check the work log for current live rollout status.

## Before installation

This guide installs into the existing project `tamirk-crt-dev`. In the live cluster inventory, `efs-sc` uses the EFS CSI provisioner and supports the backend's `ReadWriteMany` claim. Kvrocks and PostgreSQL use the default `gp3` storage class with `ReadWriteOnce` claims. The project has an 80Gi storage request quota, with 44Gi already requested by preserved PVCs; this overlay requests another 35Gi. The backend PVC is shared by several CVAT pods. Confirm the EFS access point/group behavior after its PVC is provisioned.

The OpenShift SCC injects the namespace's allowed UID and supplemental group. The chart overlay deliberately does not set fixed IDs. The data volume must be writable by that assigned identity/group. `permissionFix` is disabled because its upstream `chmod -R 777` init container cannot run under restricted-v2. If the provisioner does not provide group-writable volumes, use a supported storage class/access point configured by the storage administrator; do not grant privileged SCC or add a root chown job.

The stock `cvat/ui:v2.24.0` image uses nginx on privileged port 80. The overlay points the frontend at a small derived image that serves on 8080, with its PID and temporary files under `/tmp`. The cluster's internal registry can build and store it without Docker on the workstation. In the existing project, stage the Dockerfile and its config files, then start a binary build:

```powershell
$namespace = 'tamirk-crt-dev'
$buildDir = Join-Path $env:TEMP 'cvat-ui-openshift-build'
$configDir = Join-Path $buildDir 'helm-chart\openshift'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Copy-Item .\helm-chart\openshift\frontend.Dockerfile (Join-Path $buildDir 'Dockerfile') -Force
Copy-Item -Path .\helm-chart\openshift\nginx.conf, .\helm-chart\openshift\default.conf `
  -Destination $configDir -Force
oc new-build --binary --strategy=docker --name=cvat-ui-openshift `
  --to=cvat-ui-openshift:v2.24.0 -n $namespace
oc start-build cvat-ui-openshift --from-dir=$buildDir --follow -n $namespace
```

The overlay points at `image-registry.openshift-image-registry.svc:5000/tamirk-crt-dev/cvat-ui-openshift:v2.24.0`. If you use a different project name or external registry, update `cvat.frontend.image` accordingly. Frontend probes are disabled in the overlay because the upstream template hardcodes port 80; add an external HTTP check after the pod is running. Delete the temporary build context after the build completes.

The upstream server and Kvrocks images also need small permission changes for arbitrary OpenShift UIDs. `backend.Dockerfile` makes `/home/django` traversable, `/home/django/static` writable for `collectstatic`, and `/tmp/supervisord` writable. `kvrocks.Dockerfile` permits the startup config rewrite and PID file. Both use pinned upstream tags and keep database/application data on PVCs. The current overlay references project ImageStreams `cvat-server-openshift:v2.24.0-r2` and `cvat-kvrocks-openshift:v2.7.0-r3`. For a fresh install, build these before installing:

```powershell
$namespace = 'tamirk-crt-dev'
$serverBuildDir = Join-Path $env:TEMP 'cvat-server-build'
$kvrocksBuildDir = Join-Path $env:TEMP 'cvat-kvrocks-build'
New-Item -ItemType Directory -Force -Path $serverBuildDir,$kvrocksBuildDir | Out-Null
Copy-Item .\helm-chart\openshift\backend.Dockerfile (Join-Path $serverBuildDir 'Dockerfile') -Force
Copy-Item .\helm-chart\openshift\kvrocks.Dockerfile (Join-Path $kvrocksBuildDir 'Dockerfile') -Force
oc new-build --binary --strategy=docker --name=cvat-server-openshift `
  --to=cvat-server-openshift:v2.24.0-r2 -n $namespace
oc start-build cvat-server-openshift --from-dir=$serverBuildDir --follow -n $namespace
oc new-build --binary --strategy=docker --name=cvat-kvrocks-openshift `
  --to=cvat-kvrocks-openshift:v2.7.0-r3 -n $namespace
oc start-build cvat-kvrocks-openshift --from-dir=$kvrocksBuildDir --follow -n $namespace
```

Each build directory must contain the matching Dockerfile renamed to `Dockerfile`. If the BuildConfigs already exist, skip `oc new-build` and run `oc start-build` after updating a Dockerfile.

The overlay disables optional analytics (ClickHouse, Vector and Grafana) to limit this core annotation deployment to the dependencies needed for projects and tasks. PostgreSQL and CVAT's Kvrocks are retained. Redis is supplied as a separate StatefulSet manifest because the v2.24.0 Bitnami PostgreSQL and Redis subcharts bundle incompatible global helper definitions in this dependency combination. The Redis manifest leaves its UID unset, drops capabilities, and uses the namespace secret and an RWO PVC. Analytics can be added later after its images and volumes are validated separately.

## Install

From the repository root in PowerShell:

```powershell
oc whoami
oc project tamirk-crt-dev
oc get storageclass
```

Generate distinct random passwords and create the namespace secrets before Helm install. The CVAT chart reads `username`, `database`, and `password` from the PostgreSQL secret; Redis and Kvrocks each read `password`:

```powershell
$pgPassword = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$pgAdminPassword = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$pgReplicationPassword = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$redisPassword = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$kvrocksPassword = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
oc create secret generic cvat-postgres-secret -n tamirk-crt-dev `
  --from-literal=username=cvat --from-literal=database=cvat --from-literal=password=$pgPassword `
  --from-literal=postgres-password=$pgAdminPassword --from-literal=replication-password=$pgReplicationPassword
oc create secret generic cvat-redis-secret -n tamirk-crt-dev --from-literal=password=$redisPassword
oc create secret generic cvat-kvrocks-secret -n tamirk-crt-dev --from-literal=password=$kvrocksPassword
Remove-Variable pgPassword,pgAdminPassword,pgReplicationPassword,redisPassword,kvrocksPassword
```

These commands generate unique passwords for the CVAT DB account, PostgreSQL admin and replication accounts, Redis, and Kvrocks. They are held only in this PowerShell session and stored in namespace Secrets.

Build the dependency lock/packages for the tagged chart, render, and inspect before installation:

```powershell
helm dependency update .\helm-chart
helm lint .\helm-chart -f .\helm-chart\openshift-v2.24.yaml
helm template cvat .\helm-chart -n tamirk-crt-dev -f .\helm-chart\openshift-v2.24.yaml > .\cvat-rendered-openshift.yaml
```

Review the rendered images, PVCs, security contexts, and confirm no `user-data-permission-fix` container is present. Install only after verifying the selected storage class supports the requested claim modes. Create the Redis service before Helm starts the CVAT initializer:

```powershell
oc apply -n tamirk-crt-dev -f .\helm-chart\openshift\redis.yaml
helm upgrade --install cvat .\helm-chart -n tamirk-crt-dev `
  -f .\helm-chart\openshift-v2.24.yaml --wait --timeout 15m
```

The Redis claim uses the default storage class and requests 2Gi RWO.

Inspect PVCs and pods. Use `oc describe pvc` to verify storage binding. The backend claim explicitly uses `efs-sc`; PostgreSQL, Kvrocks and standalone Redis use the default `gp3` class.

Apply the Route without a host. OpenShift assigns one from the cluster apps domain, so no cluster-wide configuration permission is needed:

```powershell
oc apply -n tamirk-crt-dev -f .\helm-chart\openshift\routes.yaml
oc get route cvat -n tamirk-crt-dev -o wide
```

The custom frontend nginx config sends `/api`, `/admin`, `/static`, `/django-rq`, and `/profiler` requests to the backend service. The Route exposes only the frontend service.

## Validation checklist

Do not treat a successful Helm command as acceptance. Confirm:

1. Every expected Deployment/StatefulSet pod is Ready; initializer Job completed; PVCs are Bound. Check the frontend at `https://<route-host>/` because its chart probes are disabled.
2. No recurring `CrashLoopBackOff`, `ImagePullBackOff`, `FailedMount`, or permission errors in pod status/events/logs.
3. Create a CVAT superuser, open the assigned Route host, and sign in:

   ```powershell
   $backendPod = oc get pod -n tamirk-crt-dev -l tier=backend,component=server -o jsonpath='{.items[0].metadata.name}'
   oc exec -it -n tamirk-crt-dev $backendPod -c cvat-backend -- python manage.py createsuperuser
   ```

4. Create a project, create an annotation task, upload a small image, draw an annotation, save, and reload the task to confirm persistence.

Useful PowerShell checks:

```powershell
oc get deploy,sts,job,pod,pvc,route -n tamirk-crt-dev -o wide
oc get events -n tamirk-crt-dev --sort-by=.lastTimestamp
oc describe pod -n tamirk-crt-dev <pod-name>
oc logs -n tamirk-crt-dev <pod-name> --all-containers
```

## Troubleshooting

- **PVC remains Pending:** verify the cluster has a default storage class or set the approved class explicitly. Check RWX support for the CVAT backend claim and quota/capacity.
- **Permission denied on `/home/django` or Kvrocks data:** check the admitted pod UID/group (`oc get pod ... -o yaml`) and storage driver's group ownership behavior. Use a storage provisioner/access point that supports the allocated group. Do not enable the root permission-fix job or relax SCC.
- **PostgreSQL or Redis pod rejected by SCC:** make sure the overlay is being passed. Inspect the rendered PostgreSQL StatefulSet and the standalone Redis manifest for fixed IDs; both leave UID/GID selection to the namespace SCC.
- **Route returns 503:** check the Route target service/port, frontend service endpoints, and backend/frontend readiness. Confirm the frontend nginx proxy can resolve `cvat-backend-service` and that backend paths are included in its config.
- **Image pull failures:** verify registry reachability and image pull secrets for `cvat/server:v2.24.0`, the derived `cvat/ui-openshift:v2.24.0` image, Redis, and the CVAT PostgreSQL mirror.
- **Database authentication fails:** compare the namespace secret keys/values with PostgreSQL's configured user/database and CVAT pod env; do not print secret values into shared logs.
- **Initializer fails creating `secret_key.py` or data directories:** confirm its pod has the backend PVC mounted at `/home/django/data`, `keys`, `logs`, and `models` using matching `data`, `keys`, `logs`, and `models` subpaths. The OpenShift overlay configures these mounts; do not run the upstream root/chmod permission-fix job.
- **Worker liveness probes fail importing Django settings:** confirm the affected worker pod has `/home/django/data`, `/home/django/keys`, and `/home/django/logs` mounted from the backend PVC's matching subpaths. The overlay adds the missing mounts and claim references to the upstream chunks, analytics reports, quality reports, and webhooks worker templates.
- **Kvrocks reports PID/config rename permission errors:** build the derived Kvrocks image from `kvrocks.Dockerfile` and ensure the StatefulSet uses its current ImageStream tag. If only the StatefulSet pod template image changed, replace the pod; its PVC remains attached to the StatefulSet claim.
- **Helm reports another operation in progress:** inspect the active local Helm process and `helm status`/`helm history`. Let the bounded `--wait --timeout` command finish before issuing another upgrade. Preserve PVCs during release recovery.

## Upgrade/rollback

For a values or manifest change, render and inspect first, then run the same `helm upgrade --install` command. Keep the values overlay and Route manifest under source control. Do not delete PVCs during rollback or uninstall; CVAT's backend PVC is marked `helm.sh/resource-policy: keep`, and data loss requires a separately reviewed backup/restore plan.

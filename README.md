# sealos Kubernetes runtime

This repository builds sealos rootfs images for kubeadm-based Kubernetes clusters.

The scope is intentionally narrow:

- Kubernetes `1.27` through `1.36`
- `containerd` as the only CRI
- `amd64` and `arm64`
- one rootfs image per Kubernetes patch version

The previous runtime project mixed Kubernetes, k3s, Docker, CRI-O, registry setup,
bootstrap scripts, and version discovery in one tree. This rewrite keeps the
sealos runtime contract, but removes the unused CRI paths and makes the build
pipeline explicit.

## Runtime Contract

The image is a sealos `rootfs` image. The sealos lifecycle code mounts the image
onto each host, renders `*.tmpl` files with image and cluster env, and then runs
scripts from OCI labels.

Required labels provided by `Kubefile`:

- `init-cri`: installs and starts containerd
- `clean-cri`: removes containerd and CRI tooling
- `init-registry`: installs and starts the local registry on registry nodes
- `clean-registry`: removes the local registry
- `init`: installs image-cri-shim, kubelet, kubeadm, kubectl, and node sysctl
- `clean`: removes kubelet and image-cri-shim
- `check`: performs host preflight checks
- `sealos.io.kubeadm-config-helper`: points lifecycle at the helper binary
  inside the mounted rootfs

Important env defaults:

- `SEALOS_SYS_CRI_ENDPOINT=/var/run/containerd/containerd.sock`
- `SEALOS_SYS_IMAGE_ENDPOINT=/var/run/image-cri-shim.sock`
- `registryDomain=sealos.hub`
- `registryPort=5000`
- `criData=/var/lib/containerd`

The `init` label does not install containerd. Newer sealos lifecycle code runs
`init-cri` before `init`, so keeping the steps separate avoids double-starting
containerd.

## Kubeadm Config Helper

Kubernetes config APIs evolve across the supported range. For example, kubeadm
`v1.27` rejects fields that exist in newer kubelet and kube-proxy config APIs,
while Kubernetes `v1.31+` needs kubeadm `v1beta4` behavior. To keep version
knowledge close to the runtime that ships the Kubernetes binaries,
`scripts/build-rootfs.sh` builds `cmd/kubeadm-config-gen` into every image at:

```text
/opt/sealos/bin/kubeadm-config-gen
```

The image advertises the helper through OCI labels:

```text
sealos.io.kubeadm-config-helper=/opt/sealos/bin/kubeadm-config-gen
sealos.io.kubeadm-config-helper-api=v1
sealos.io.kubeadm-config-helper-mode=sanitize
```

The helper is compiled per Kubernetes patch version. For a runtime image built
with Kubernetes `v1.27.16`, the helper build links `k8s.io/kubelet`,
`k8s.io/kube-proxy`, and `k8s.io/apimachinery` at `v0.27.16`; for Kubernetes
`v1.36.1`, it links the same modules at `v0.36.1`. The helper uses those linked
component config types to derive the kubelet and kube-proxy YAML schema and
prunes only fields unknown to that exact Kubernetes version, while preserving
the original values and formatting shape of known fields.

Current sealos lifecycle code discovers those labels after mounting the rootfs,
runs the helper with the target Kubernetes version, and falls back to its own
sanitizer only when the image does not provide a helper.

## Build A Single Image

Install a recent sealos binary first, then build one target:

```bash
sudo scripts/build-rootfs.sh \
  --kubernetes-version v1.36.1 \
  --arch amd64 \
  --image ghcr.io/your-org/runtime/kubernetes:v1.36.1-amd64
```

To push:

```bash
sudo sealos login ghcr.io -u "$GITHUB_ACTOR" -p "$GITHUB_TOKEN"
sudo scripts/build-rootfs.sh \
  --kubernetes-version v1.36.1 \
  --arch amd64 \
  --image ghcr.io/your-org/runtime/kubernetes:v1.36.1-amd64 \
  --push
```

Useful overrides:

```bash
sudo scripts/build-rootfs.sh \
  --kubernetes-version v1.36.1 \
  --arch arm64 \
  --image ghcr.io/your-org/runtime/kubernetes:v1.36.1-arm64 \
  --containerd-version v2.3.1 \
  --runc-version v1.4.2 \
  --sealos-version latest
```

If you are testing against a locally built sealos lifecycle tree, point the build
at the Linux binaries:

```bash
sudo scripts/build-rootfs.sh \
  --kubernetes-version v1.36.1 \
  --arch amd64 \
  --image localhost/kubernetes:v1.36.1-amd64 \
  --sealos-bin-dir /path/to/sealos/bin/linux_amd64
```

The directory must contain `image-cri-shim` and should contain `sealctl`. If
`sealctl` is absent, sealos will still try to sync the client-side `sealctl`
during `MountRootfs`, but including it in the image makes the rootfs easier to
test independently.

## Resolve Supported Versions

Print latest patch releases for all supported minors:

```bash
scripts/resolve-versions.sh --versions-only
```

Print a GitHub Actions matrix:

```bash
scripts/resolve-versions.sh --matrix --arches amd64,arm64
```

Generate a small matrix for one debug build:

```bash
scripts/resolve-versions.sh \
  --matrix \
  --kubernetes-version v1.36.1 \
  --arches amd64
```

The resolver reads `.github/versions/supported-minors.txt` and asks
`dl.k8s.io` for `stable-<minor>.txt`, so new patch releases do not require a
repository change.

## GitHub Actions

The workflow runs on pushes to `main` and can also be started manually. By
default it builds the latest patch release for each supported Kubernetes minor
on both `amd64` and `arm64`.

Useful dispatch inputs:

- `kubernetes_version`: set this to a patch version such as `v1.36.1` to build
  one Kubernetes release instead of every supported minor.
- `arch`: choose `amd64` or `arm64` to validate one architecture quickly. Keep
  `all` for a full multi-arch build.
- `push`: when `false`, the workflow performs build validation without pushing.
  When `true`, it pushes arch-specific tags and, for `arch=all`, a multi-arch
  manifest tag.

Example quick validation:

```bash
gh workflow run build.yml \
  --repo lingdie/sealos-runtime \
  -f kubernetes_version=v1.36.1 \
  -f arch=amd64 \
  -f push=false \
  -f all_images=false
```

Pushes to `main` also run the same validation workflow with default inputs.

## Offline Images

`scripts/build-rootfs.sh` generates `images/shim/DefaultImageList` with:

```bash
kubeadm config images list --kubernetes-version <version>
```

During `sealos build`, sealos scans that file and stores the images into the
rootfs `registry/` directory. The lifecycle code later syncs that registry
directory to the cluster registry before kubeadm starts.

## Repository Layout

```text
Kubefile                  sealos rootfs image definition
rootfs/                   files copied into the image
rootfs/scripts/           lifecycle scripts run on target hosts
rootfs/etc/*.tmpl         templates rendered by sealos before bootstrap
scripts/build-rootfs.sh   build one arch/version image
scripts/resolve-versions.sh
.github/workflows/        CI build and manifest workflow
tmp/                      old runtime and lifecycle references, not used by CI
```

## Compatibility Notes

This project uses containerd config `version = 3`, the format used by
containerd 2.x. The default build tracks current containerd 2.x releases. If you
need to pin containerd 1.7 for an older environment, keep a separate v2 config
template rather than mixing old and new plugin names in one file.

The matching sealos lifecycle branch owns cluster init, join, upgrade, registry
sync, and helper execution. It must understand `sealos.io.kubeadm-config-helper`
labels and containerd 2.x cgroup config paths. The `tmp/` directory here is only
historical reference material.

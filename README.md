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

Important env defaults:

- `SEALOS_SYS_CRI_ENDPOINT=/run/containerd/containerd.sock`
- `SEALOS_SYS_IMAGE_ENDPOINT=/var/run/image-cri-shim.sock`
- `registryDomain=sealos.hub`
- `registryPort=5000`
- `criData=/var/lib/containerd`

The `init` label does not install containerd. Newer sealos lifecycle code runs
`init-cri` before `init`, so keeping the steps separate avoids double-starting
containerd.

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

The resolver reads `.github/versions/supported-minors.txt` and asks
`dl.k8s.io` for `stable-<minor>.txt`, so new patch releases do not require a
repository change.

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

This project uses containerd config `version = 3`, the format introduced for
containerd 2.x. The default build tracks current containerd 2.x releases. If you
need to pin containerd 1.7 for an older environment, keep a separate v2 config
template rather than mixing old and new plugin names in one file.

The lifecycle code in `tmp/lifecycle` currently owns kubeadm config generation,
cluster init, join, upgrade, and registry sync. This repository only provides
the rootfs content and the labels/env that lifecycle expects.

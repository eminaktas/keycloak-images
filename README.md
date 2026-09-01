# Keycloak images

Wolfi-based images for the official Keycloak server and Keycloak Operator. A single [Melange](https://github.com/chainguard-dev/melange) build produces the server package and the operator subpackage from the same upstream checkout, then [APKO](https://github.com/chainguard-dev/apko) assembles the two images and [Cosign](https://github.com/sigstore/cosign) signs them.

| Component | Image                                 | Compatible runtime contract                          |
|-----------|---------------------------------------|------------------------------------------------------|
| Server    | `ghcr.io/eminaktas/keycloak`          | `/opt/keycloak`, UID 1000, `kc.sh` entrypoint        |
| Operator  | `ghcr.io/eminaktas/keycloak-operator` | `/opt/keycloak`, UID 1000, Quarkus runner entrypoint |

## Repository model

There is no release application in this repository. [`config/versions.json`](config/versions.json) is the release catalog, three templates define the combined package build and two images, and [`hack/render.sh`](hack/render.sh) performs plain placeholder replacement plus optional per-track build-step rendering.

Versioned directories below `bump/` can contain Maven overrides. When a file is absent, its pipeline step or input is omitted:

| Track file                     | Rendered Melange behavior                            |
|--------------------------------|------------------------------------------------------|
| `bump/<track>/pom.patch`       | Adds the `patch` pipeline using `pom.patch`          |
| `bump/<track>/deps.yaml`       | Applies Maven dependency overrides with Omnibump     |
| `bump/<track>/properties.yaml` | Applies Maven property overrides with Omnibump       |

For example, the `bump/26.7/` overrides are copied into `_output/26.7/` beside the rendered recipe for Melange. Signing keys and generated packages are therefore not copied into the build workspace.

## Active tracks

| Track  | Keycloak  | Kubernetes resources | Server Java | Operator Java |
|--------|----------:|---------------------:|------------:|--------------:|
| `26.4` | `26.4.15` | `26.4.7`             | 21          | 21            |
| `26.6` | `26.6.6`  | `26.6.4`             | 21          | 21            |
| `26.7` | `26.7.3`  | `26.7.3`             | 21          | 21            |

## Tags

Each image receives the same tag set:

| Form                            | Example     |
|---------------------------------|-------------|
| version and repository revision | `26.7.3-r0` |
| upstream version                | `26.7.3`    |
| active track                    | `26.7`      |
| default track                   | `latest`    |

Only the track selected by `latestTrack` receives `latest`. During release, the operator is rendered again with the published server digest in `RELATED_IMAGE_KEYCLOAK`, keeping the pair linked even when floating tags move later.

The version-and-revision tag is immutable. The release workflow refuses to overwrite it, so increment the track's `revision` before a release-triggering change that keeps the same upstream version. The scheduled updater does this automatically when only the Kubernetes resources advance.

## Run the server

```bash
docker run --rm -p 8080:8080 -p 9000:9000 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=change-me \
  -e KC_HEALTH_ENABLED=true \
  ghcr.io/eminaktas/keycloak:latest start-dev
```

## Use the operator

Install the track's [official Keycloak Kubernetes resources](https://github.com/keycloak/keycloak-k8s-resources), then select this operator image and remove the server-image override from the official Deployment:

```bash
kubectl -n keycloak set image deployment/keycloak-operator \
  keycloak-operator=ghcr.io/eminaktas/keycloak-operator:26.7.3-r0
kubectl -n keycloak set env deployment/keycloak-operator \
  RELATED_IMAGE_KEYCLOAK-
```

The official YAML sets `RELATED_IMAGE_KEYCLOAK` explicitly, and a Kubernetes environment value overrides the default embedded in the container image. Removing it makes the operator use the server digest bound into this operator image at release time. Alternatively, set it explicitly to the desired `ghcr.io/eminaktas/keycloak` reference.

## Build locally

Local builds require `jq`, Melange, APKO, and Docker. Kind and `kubectl` are needed only for the pair test.

```bash
make validate
make images STREAM=26.7 ARCH=x86_64
```

Generated definitions, copied track overrides, and artifacts are written below `_output/<track>`.

Release APKs are built in parallel on matching native GitHub runners. In
particular, `aarch64` uses `ubuntu-24.04-arm`, avoiding the large QEMU penalty
of compiling the Keycloak Maven reactor on an x86 runner. The publish job then
assembles the multi-architecture images from both signed package repositories.

```bash
make pair-test STREAM=26.7 \
  SERVER_IMAGE=keycloak-images/keycloak:26.7.3-r0-amd64 \
  OPERATOR_IMAGE=keycloak-images/keycloak-operator:26.7.3-r0-amd64
```

## Verify a release

The release workflow signs images with a private key. The matching public key is committed as [`cosign.pub`](./cosign.pub).

```bash
cosign verify \
  --key https://raw.githubusercontent.com/eminaktas/keycloak-images/refs/heads/main/cosign.pub \
  ghcr.io/eminaktas/keycloak:latest
```

Release APKs use a separate signing key, and APKO verifies them with the committed [`melange.rsa.pub`](./melange.rsa.pub).

## License

This project is licensed under the [Apache-2.0 License](./LICENSE).

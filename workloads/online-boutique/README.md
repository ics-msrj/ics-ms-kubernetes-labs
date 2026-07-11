# Workload — Online Boutique

Every module in this lab deploys and operates the same application: **Online Boutique**, an 11-service e-commerce demo built and maintained by Google.

- **Source**: [`GoogleCloudPlatform/microservices-demo`](https://github.com/GoogleCloudPlatform/microservices-demo)
- **License**: Apache License 2.0 (see the header of the vendored manifest below)
- **Pinned version**: `v0.10.5` (release manifest, fetched 2026-07)

## What's vendored here

[`upstream/kubernetes-manifests.yaml`](upstream/kubernetes-manifests.yaml) is copied **unmodified** from upstream's `release/kubernetes-manifests.yaml` at the pinned version above. It is not edited in place — module-specific changes are layered on top as separate manifests (e.g. Module 02 replaces the `redis-cart` Deployment with a StatefulSet). This keeps the provenance of the upstream file clear and makes it easy to diff against a newer upstream release later.

## Components

| Component | Role | Protocol |
|---|---|---|
| `frontend` | Web UI, session handling | HTTP |
| `cartservice` | Shopping cart | gRPC, backed by `redis-cart` |
| `productcatalogservice` | Product listing/search | gRPC |
| `currencyservice` | Currency conversion | gRPC |
| `paymentservice` | Mock payment processing | gRPC |
| `shippingservice` | Shipping cost + tracking | gRPC |
| `emailservice` | Mock order confirmation email | gRPC |
| `checkoutservice` | Orchestrates an order (calls cart, payment, shipping, email) | gRPC |
| `recommendationservice` | "You might also like" | gRPC |
| `adservice` | Contextual ads | gRPC |
| `loadgenerator` | Locust-based synthetic user traffic | HTTP client |
| `redis-cart` | Cart storage | Redis protocol |

Eleven application services plus Redis — the number you'll see quoted throughout this repo's docs.

## Images

All service images are pulled from Google's public registry (`us-central1-docker.pkg.dev/google-samples/microservices-demo/*`) — **you never need to build or push an image to run this lab.** `redis-cart` uses the public `redis:alpine` image, and `loadgenerator` has an init container using public `busybox:latest`.

## Updating the pinned version

1. Check the [upstream releases](https://github.com/GoogleCloudPlatform/microservices-demo/releases) for a newer tag.
2. Re-fetch: `curl -fsSL https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/<tag>/release/kubernetes-manifests.yaml -o upstream/kubernetes-manifests.yaml`
3. Diff against the module-specific overrides (Module 02's `redis-cart` replacement, in particular) — a new upstream release may change fields this repo depends on (env var names, container ports, probe types).
4. Update the pinned version noted above.

# Architecture — Microservices Platform (portfolio)

> Project goal: learn microservices architecture and infrastructure decisions in .NET
> in depth, so they can be explained in a technical interview —
> not just have the code working.

## Diagram

```
                                   ┌─────────────────────┐
                                   │   Client (SPA /      │
                                   │   Postman / curl)    │
                                   └──────────┬───────────┘
                                              │ HTTPS
                                              ▼
                              ┌───────────────────────────────┐
                              │        API GATEWAY (YARP)      │
                              │  - Validates JWT (once)        │
                              │  - Routes by path               │
                              │  - Centralized rate limiting     │
                              └───┬──────────┬──────────┬──────┘
                                  │          │          │
                     ┌────────────┘          │          └────────────┐
                     ▼                       ▼                       ▼
           ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────────┐
           │   Users.Api        │   │  Catalog.Api      │   │   Orders.Api          │
           │  (login, issues    │   │  (product CRUD)   │   │  (creates orders,     │
           │   JWT)             │   │                    │   │   queries Catalog)    │
           │  ┌──────────────┐  │   │  ┌──────────────┐ │   │  ┌──────────────┐    │
           │  │ users_db     │  │   │  │ catalog_db   │ │   │  │ orders_db    │    │
           │  │ (Postgres)   │  │   │  │ (Postgres)   │ │   │  │ (Postgres)   │    │
           │  └──────────────┘  │   │  └──────────────┘ │   │  └──────────────┘    │
           └──────────────────┘   └──────────────────┘   └──────────┬───────────┘
                                                                      │
                                                        "OrderCreated" event
                                                           (RabbitMQ, async)
                                                                      │
                                                                      ▼
                                                        ┌──────────────────────┐
                                                        │  Notifications.Api    │
                                                        │  (SignalR Hub)        │
                                                        └──────────┬───────────┘
                                                                   │ WebSocket
                                                                   ▼
                                                        ┌──────────────────────┐
                                                        │  Live dashboard        │
                                                        └──────────────────────┘

All orchestrated with docker-compose (internal network, one container per service + per DB + RabbitMQ)
```

## Components

| Component | Responsibility |
|---|---|
| `Users.Api` | Registration/login, JWT issuance, own DB (`users_db`) |
| `Catalog.Api` | Product CRUD, own DB (`catalog_db`) |
| `Orders.Api` | Creates orders, queries Catalog over HTTP, own DB (`orders_db`), publishes `OrderCreated` event |
| `Gateway` (YARP) | Single entry point, validates JWT, routes, rate limiting |
| `Notifications.Api` | Consumes `OrderCreated` from RabbitMQ, pushes to connected clients via SignalR |
| RabbitMQ | Messaging broker for the `OrderCreated` event |
| Dashboard | Minimal client connected via SignalR to see live notifications |

## Decisions made and why

### 1. Database per service (not shared)
Each service owns its schema → it can change without coordinating deploys with other
services, and each one scales/migrates independently.
**Cost**: no SQL JOIN across services — Orders *asks* Catalog for the data instead of
reading it directly from its DB. Eventual consistency instead of transactional.

### 2. JWT validated at the Gateway (not in each service) — "perimeter trust"
- **Pro**: a single place validates signature/expiration/claims; the services trust the
  internal docker-compose network.
- **Con**: if something calls a container directly without going through the Gateway,
  there is no second validation. In production at larger scale (K8s, more attack surface)
  this is combined with lightweight validation in each service or mTLS (zero-trust). For
  this scope, perimeter trust is the standard and correct decision.

### 3. Gateway: YARP (not Ocelot)
| | YARP | Ocelot |
|---|---|---|
| Maintained by | Microsoft, active | Community, slower development |
| Performance | High (on top of Kestrel) | Lower (custom pipeline) |
| Configuration | Library — C# code or JSON with dynamic reload | Closed framework — 100% `ocelot.json` |
| Out-of-the-box features | None extra (rate limiting/caching are added with standard ASP.NET Core middleware) | Caching, request aggregation, QoS with Polly, own rate limiting |

Chosen YARP: better performance, and by writing the JWT middleware ourselves we
understand (and can explain) exactly how validation works, instead of
depending on "magic" configuration.

### 4. PostgreSQL (not SQL Server)
De facto standard in microservices/cloud-native, lightweight container, free. Good
portfolio signal of not being tied to a single vendor (the dev already knows SQL Server
from professional experience).

### 5. Orders → Notifications: async via RabbitMQ (not direct HTTP)
- **Chosen**: Orders publishes an `OrderCreated` event, Notifications consumes it and
  pushes via SignalR. Decoupled and resilient — Orders doesn't depend on Notifications
  being up. A real event-driven architecture pattern.
- **Cost**: adds infrastructure (the broker) and brings eventual consistency and
  idempotency concerns (what happens if the message is processed twice).
- **Discarded alternative**: direct sync HTTP (simpler, but couples the two services at
  runtime).

## Alternatives discarded upfront

| Alternative | Why not |
|---|---|
| Kubernetes instead of docker-compose | Adds operational complexity (manifests, ingress) without adding microservices-specific learning. Left as a "next step" mentioned in the final README. |
| Service mesh (Istio/Linkerd) | Solves observability/mTLS at the scale of dozens of services; with 3 it's over-engineering. |
| Dynamic service discovery (Consul/Eureka) | In docker-compose the service name is already internal DNS (`http://catalog-api:8080`). Only adds value with multiple instances/auto-scaling. |
| gRPC between all services | Better performance for high internal traffic, but REST is easier to debug/explain at this volume. Mentioned as "would do differently at larger scale". |

## Build plan (blocks)

- [x] **Block 0** — Solution structure + `docker-compose.yml` skeleton (Postgres x3, RabbitMQ, no .NET services yet)
- [ ] **Block 1** — `Users.Api`: registration/login, JWT issuance
- [ ] **Block 2** — `Catalog.Api`: product CRUD
- [ ] **Block 3** — `Orders.Api`: creates orders, queries Catalog over HTTP
- [ ] **Block 4** — `Gateway` (YARP): routing + centralized JWT validation + rate limiting
- [ ] **Block 5** — `Notifications.Api` (SignalR) + RabbitMQ integration (`OrderCreated`)
- [ ] **Block 6** — Minimal dashboard connected via SignalR
- [ ] **Block 7** — Full `docker-compose.yml` + final README with diagram and local setup guide

After each block: infrastructure decisions made, trade-offs, possible
interview questions, and 3-4 bullets of "what you learned" for personal notes.

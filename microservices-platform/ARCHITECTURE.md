# Arquitectura — Microservices Platform (portfolio)

> Objetivo del proyecto: aprender a fondo decisiones de arquitectura e infraestructura
> de microservicios en .NET, para poder explicarlas en una entrevista técnica —
> no solo tener el código funcionando.

## Diagrama

```
                                   ┌─────────────────────┐
                                   │   Cliente (SPA /     │
                                   │   Postman / curl)    │
                                   └──────────┬───────────┘
                                              │ HTTPS
                                              ▼
                              ┌───────────────────────────────┐
                              │        API GATEWAY (YARP)      │
                              │  - Valida JWT (una sola vez)   │
                              │  - Enruta por path              │
                              │  - Rate limiting centralizado   │
                              └───┬──────────┬──────────┬──────┘
                                  │          │          │
                     ┌────────────┘          │          └────────────┐
                     ▼                       ▼                       ▼
           ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────────┐
           │   Users.Api        │   │  Catalog.Api      │   │   Orders.Api          │
           │  (login, emite     │   │  (CRUD productos) │   │  (crea pedidos,       │
           │   JWT)             │   │                    │   │   consulta Catalog)   │
           │  ┌──────────────┐  │   │  ┌──────────────┐ │   │  ┌──────────────┐    │
           │  │ users_db     │  │   │  │ catalog_db   │ │   │  │ orders_db    │    │
           │  │ (Postgres)   │  │   │  │ (Postgres)   │ │   │  │ (Postgres)   │    │
           │  └──────────────┘  │   │  └──────────────┘ │   │  └──────────────┘    │
           └──────────────────┘   └──────────────────┘   └──────────┬───────────┘
                                                                      │
                                                        evento "OrderCreated"
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
                                                        │  Dashboard en vivo     │
                                                        └──────────────────────┘

Todo orquestado con docker-compose (red interna, un contenedor por servicio + por DB + RabbitMQ)
```

## Componentes

| Componente | Responsabilidad |
|---|---|
| `Users.Api` | Registro/login, emisión de JWT, DB propia (`users_db`) |
| `Catalog.Api` | CRUD de productos, DB propia (`catalog_db`) |
| `Orders.Api` | Crea pedidos, consulta a Catalog por HTTP, DB propia (`orders_db`), publica evento `OrderCreated` |
| `Gateway` (YARP) | Único punto de entrada, valida JWT, enruta, rate limiting |
| `Notifications.Api` | Consume `OrderCreated` de RabbitMQ, empuja por SignalR a clientes conectados |
| RabbitMQ | Broker de mensajería para el evento `OrderCreated` |
| Dashboard | Cliente mínimo conectado por SignalR para ver notificaciones en vivo |

## Decisiones tomadas y por qué

### 1. Base de datos por servicio (no compartida)
Cada servicio es dueño de su esquema → se puede cambiar sin coordinar deploys con otros
servicios, y cada uno escala/migra de forma independiente.
**Costo**: no hay JOIN SQL entre servicios — Orders le *pide* el dato a Catalog en vez de
leerlo directo de su DB. Consistencia eventual en vez de transaccional.

### 2. JWT validado en el Gateway (no en cada servicio) — "perimeter trust"
- **Pro**: un solo lugar valida firma/expiración/claims; los servicios confían en la red
  interna de docker-compose.
- **Contra**: si algo llama directo a un contenedor sin pasar por el Gateway, no hay
  segunda validación. En producción a mayor escala (K8s, más superficie de ataque) esto
  se combina con validación ligera en cada servicio o mTLS (zero-trust). Para este scope,
  perimeter trust es la decisión estándar y correcta.

### 3. Gateway: YARP (no Ocelot)
| | YARP | Ocelot |
|---|---|---|
| Mantenido por | Microsoft, activo | Comunidad, desarrollo más lento |
| Performance | Alto (sobre Kestrel) | Menor (pipeline propio) |
| Configuración | Librería — código C# o JSON con reload dinámico | Framework cerrado — 100% `ocelot.json` |
| Features de fábrica | Ninguna extra (rate limiting/caching se agregan con middleware estándar ASP.NET Core) | Caching, agregación de requests, QoS con Polly, rate limiting propio |

Elegido YARP: mejor performance, y al escribir el middleware de JWT nosotros mismos
entendemos (y podemos explicar) exactamente cómo funciona la validación, en vez de
depender de configuración "mágica".

### 4. PostgreSQL (no SQL Server)
Estándar de facto en microservicios/cloud-native, contenedor liviano, gratis. Buena señal
de portfolio de no estar atado a un solo vendor (el dev ya domina SQL Server de su
experiencia profesional).

### 5. Orders → Notifications: asíncrono vía RabbitMQ (no HTTP directo)
- **Elegido**: Orders publica evento `OrderCreated`, Notifications lo consume y empuja
  por SignalR. Desacoplado y resiliente — Orders no depende de que Notifications esté
  arriba. Patrón real de arquitectura event-driven.
- **Costo**: suma infraestructura (el broker) y trae temas de consistencia eventual e
  idempotencia (qué pasa si el mensaje se procesa dos veces).
- **Alternativa descartada**: HTTP directo sync (más simple, pero acopla los dos
  servicios en tiempo de ejecución).

## Alternativas descartadas de entrada

| Alternativa | Por qué no |
|---|---|
| Kubernetes en vez de docker-compose | Suma complejidad operativa (manifests, ingress) sin sumar aprendizaje de microservicios en sí. Queda como "próximo paso" mencionado en el README final. |
| Service mesh (Istio/Linkerd) | Resuelve observability/mTLS a escala de decenas de servicios; con 3 es sobre-ingeniería. |
| Service discovery dinámico (Consul/Eureka) | En docker-compose el nombre del servicio ya es DNS interno (`http://catalog-api:8080`). Solo aporta valor con múltiples instancias/auto-scaling. |
| gRPC entre todos los servicios | Mejor performance para tráfico interno alto, pero REST es más fácil de debuggear/explicar para este volumen. Mencionado como "lo haría distinto a mayor escala". |

## Plan de construcción (bloques)

- [ ] **Bloque 0** — Estructura de solución + skeleton `docker-compose.yml` (Postgres x3, RabbitMQ, sin servicios .NET todavía)
- [ ] **Bloque 1** — `Users.Api`: registro/login, emisión JWT
- [ ] **Bloque 2** — `Catalog.Api`: CRUD productos
- [ ] **Bloque 3** — `Orders.Api`: crea pedidos, consulta Catalog por HTTP
- [ ] **Bloque 4** — `Gateway` (YARP): enrutamiento + validación JWT centralizada + rate limiting
- [ ] **Bloque 5** — `Notifications.Api` (SignalR) + integración RabbitMQ (`OrderCreated`)
- [ ] **Bloque 6** — Dashboard mínimo conectado por SignalR
- [ ] **Bloque 7** — `docker-compose.yml` completo + README final con diagrama y guía de levantamiento local

Después de cada bloque: decisiones de infraestructura tomadas, trade-offs, posibles
preguntas de entrevista, y 3-4 bullets de "lo que aprendiste" para notas propias.

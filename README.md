# Digital Wallet: High Level Design (MVP)

**Architecture style:** Modular monolith
**Sources:** the HLD diagram and the system design notes (Digital Wallet MVP)

---

## 1. Goals and scope

**The system does**
- Send money between wallets (`transfer-money`) with an idempotency key, using synchronous communication for consistency.
- Payment flow for merchants: create payment URL, payment page, phone + OTP, validate OTP and deduct money, then callback/webhook.
- Wallet, transaction and ledger tracking, with fees and limits that are configurable.
- Account activation (Pending until approved by an authorized person).
- Fraud detection, notifications, analytics and logs.

**The system does not do (for now)**
- Multi-currency: only `EGP` today. The schema keeps `currency`, so adding currencies later is possible.
- External payment gateway: planned for the future.
- Microservices: modules have clear boundaries and can be split later if needed.

---

## 2. Capacity estimate (from the notes)

```text
10M users x 10 transactions/day = 100M transactions/day
Average  = 100M / 86,400  ~ 1.16K RPS
Peak     = 2x to 5x       ~ 2.3K to 5.8K RPS
```

---

## 3. Architecture

```text
                         Client (web / mobile)
                                  |
                                  v
                         Load Balancer
                                  |
                                  v
        +-----------------------------------------------+
        |   App (modular monolith)                      |        +-----------------+
        |   - auth / user (account) module              | <----> | Redis cluster   |
        |   - payment module                            |        | (more than one  |
        |   - wallet module (+ ledger)                  |        |  node)          |
        |   - fraud detection module                    |        +-----------------+
        |   - workers                                   |
        +-----------+-----------------------+-----------+
                    |                       |
                    v                       v
        +---------------------+    +-----------------------+
        | DB                  |    | Kafka (cluster)       |
        | primary: writes and |    | topics: notification, |
        |   reads on          |    | fraud, analytics,     |
        |   transactions      |    | logs                  |
        | replicas: reads     |    +-----------+-----------+
        +----------^----------+                |
                   |                           v
                   +------------------  Workers (same codebase)
                                        consume events, update DB,
                                        send callbacks/webhooks
```

---

## 4. Components

| Component | Role |
|---|---|
| **Load Balancer** | Entry point for all client traffic; spreads requests across App instances. |
| **App (modular monolith)** | One deployable with separate modules and clear boundaries between them. |
| auth/user module | Registration, login, account status (Pending/Active), phone verification. |
| wallet module | Wallets, balances, wallet transactions, ledger, limits, fees. |
| payment module | Payment URLs, OTP, payment execution, redirect, webhook/callback triggering. |
| fraud detection module | Detects suspicious activity (e.g. many failed payments) and can block a wallet. |
| **Workers** | Same codebase as the App, run as processes that read from Kafka and do background work. |
| **DB** | Primary for writes and for reads on transactions; replicas for read-only queries. |
| **Redis cluster** | Fast in-memory store, run as a cluster to avoid a single point of failure. |
| **Kafka cluster** | Event stream for notification, fraud, analytics and logs. |

---

## 5. Flows

### 5.1 Send money (synchronous, for consistency)

```http
POST /api/v1/transfer-money
Authorization: Bearer <token>
X-Idempotency-Key: <uuid>

{ "phone": "01000...", "amount": 100 }
```

1. Request goes Client, Load Balancer, App (wallet module).
2. The idempotency key prevents the same transfer from running twice on retry.
3. Balance check, debit, credit, transaction and ledger entries happen in the DB (primary), in one transaction.
4. Result is returned to the client in the same request.
5. An event is published to Kafka afterwards (notification, fraud, analytics, logs).

### 5.2 Payment (merchant checkout)

```text
Merchant           App (payment module)            Customer
   |                        |                          |
   | create-payment-url --> |                          |
   | <-- payment URL ------ |                          |
   |                        |                          |
   |    redirect customer to payment page ------------>|
   |                        | <-- phone number ------- |
   |                        | --- create + send OTP -> |
   |                        | <-- OTP ---------------- |
   |                        | validate OTP             |
   |                        | deduct money (wallet)    |
   |                        | status change            |
   | <-- callback/webhook --|                          |
   |                        | --- redirect ----------> |
```

```http
POST /api/v1/payment/create-payment-url
Authorization: <api-key>

{
  "amount": 200,
  "vat_amount": "",
  "meta_data": {},
  "products": [],
  "user": {},
  "order_id": "..."
}
```

- `order_id` is used as `client_ref_id`.
- OTP: sent to the phone, validated in the payment step, with limits on requests per day and per payment.
- The webhook carries `X-Signature-Value`, verified with the service/client secret key.

### 5.3 Background work

1. The App publishes events to Kafka.
2. Workers consume them: notification, fraud, analytics, logs.
3. Workers read and write the DB when needed and send callbacks/webhooks.

---

## 6. Data stores

| Store | What it holds |
|---|---|
| **DB primary** | Users, wallets, wallet transactions, ledger, idempotency keys, payments, OTP. All writes. |
| **DB replicas** | Read-only queries (history, reports). |
| **Redis** | Short-lived data and rate limiting (exact usage to be confirmed, see section 9). |
| **Kafka** | Events in transit; not a source of truth. |

Core tables (from the notes): `users`, `wallets`, `wallet_transactions`, `wallet_ledger`, `otp`, `idempotency`.

Business rules (from the notes):
- Send limits: 20K/day, 50 transactions/day, 300K/month, 350 transactions/month.
- Receive: no limit on count, but a max wallet balance (default 400K per currency).
- Limits and fees are configurable and can be overridden per user by an authorized admin.

---

## 7. Single points of failure (known)

| Component | Status in the diagram | Planned |
|---|---|---|
| Redis | Cluster | Covered |
| Kafka | Cluster | Covered |
| Load Balancer | Single | More than one instance |
| App | Single box | Multiple instances behind the LB |
| DB primary | Single primary | Standby that can take over as primary |
| Webhook delivery | Not detailed | Retry on failure |

---

## 8. Cross-cutting (from the notes)

- HTTPS for all APIs.
- Rate limiting, with settings per service/route.
- Logs and audit logs.
- Race conditions handled for any operation that changes a wallet balance.
- DDoS/DoS protection through an external service (e.g. Cloudflare).
- Fraud: repeated failed attempts handled by an async job, with a temporary wallet block and a full account block until an admin acts.

---

## 9. Open decisions (to settle, not assumed)

1. **Fraud:** is it a check inside the request path, or only a consumer of events?
2. **Workers:** same codebase as the App, deployed as separate processes? (The diagram draws them twice.)
3. **Webhook/callback sender:** which component sends it and where retry logic lives.
4. **Redis usage:** exactly which data (OTP, rate limit counters, idempotency fast path, other).
5. **Where auth and rate limiting run:** the LB is not a gateway, so confirm they are App middleware.

---

## 10. Possible evolution

If load or team size grows, modules can be split into services. The first candidates are the least money-critical parts (workers, notification, fraud, webhook delivery). The wallet and ledger should be split last, because they need a single transaction.
